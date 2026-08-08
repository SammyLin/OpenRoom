"""Qwen3-ASR streaming worker——**跑在自己的 process**。

這是整份重寫最重要的一條線。舊版把推論放在收音的同一條路上（``whisper_mlx.py:246``
的 ``send()`` 抓著鎖 inline await final 轉錄），推論一慢，後面的音訊就在鎖上排隊，越
講越落後，最後看起來像「不會收音」。

這裡的收音永遠不會等推論：audio 進 queue 就結束，推論在另一個 process。queue 滿了
就丟最舊的，**並且送出 ``gap`` 事件**——丟可以，靜靜地丟不行。

冷啟動：第一次 ``feed_audio`` 要編譯 Metal kernel，實測 46 秒。所以 worker 會先用靜音
預熱，預熱完才回報 ready。這 46 秒若發生在會議開始，就是整段開場消失。
"""

from __future__ import annotations

import multiprocessing as mp
import queue
import time
from dataclasses import dataclass

import numpy as np
import zhconv

SAMPLE_RATE = 16_000
# 每次餵給模型的音訊長度。實測見 docs/measurements.md：1.0 秒兩個延遲 gate 都過，
# 2.0 秒 partial 延遲爆掉（單塊推論太久），0.5 秒 RTF > 1 直接進入死亡螺旋。
CHUNK_SEC = 1.0
# 低於這個 RMS 且沒有新文字，就當靜音。**會送出 no_speech 事件**，不是默默跳過。
SILENCE_RMS = 0.005


@dataclass
class WorkerConfig:
    model: str = "Qwen/Qwen3-ASR-0.6B"
    language: str | None = None  # None = 讓模型自己判斷（中英夾雜需要）
    chunk_sec: float = CHUNK_SEC
    # 直覺上「切在講話停頓」(energy) 應該比「每 chunk_sec 硬切」(fixed) 好，實測相反：
    # energy 的 WER 更差而且延遲 P95 爆到 4.3 秒。見 docs/measurements.md。
    endpointing: str = "fixed"


def _common_prefix_len(a: str, b: str) -> int:
    n = min(len(a), len(b))
    i = 0
    while i < n and a[i] == b[i]:
        i += 1
    return i


def _emit(out: mp.Queue, event: dict) -> None:
    # Qwen3-ASR 中文一律吐簡體，使用者是台灣人，讀起來就是不對，而且拿繁體逐字稿
    # 當 reference 時每個簡體字都算一次取代，WER 被灌水。轉換放在唯一的出口，
    # 不是每個 _emit 呼叫點各轉一次。英文是 no-op。
    if event.get("text"):
        event = {**event, "text": zhconv.convert(event["text"], "zh-tw")}
    try:
        out.put_nowait(event)
    except queue.Full:  # pragma: no cover - out queue 是無上限的
        pass


def run(cfg: WorkerConfig, audio_q: mp.Queue, out_q: mp.Queue) -> None:
    """Worker process 進入點。只從 audio_q 讀 PCM，只往 out_q 寫事件。"""
    try:
        from mlx_qwen3_asr import streaming as st
    except ImportError as exc:
        _emit(out_q, {"type": "error", "code": "mlx_missing",
                      "message": f"載入 mlx-qwen3-asr 失敗：{exc}", "fatal": True})
        return

    try:
        # 預熱：先用一個丟棄的 state 把 Metal kernel 編譯掉（實測 ~46 秒）。
        # 模型權重留在 process 內，真正的 state 初始化就很快。
        t0 = time.monotonic()
        warm = st.init_streaming(model=cfg.model, chunk_size_sec=cfg.chunk_sec,
                                 language=cfg.language,
                                 endpointing_mode=cfg.endpointing)
        st.feed_audio(np.zeros(int(SAMPLE_RATE * cfg.chunk_sec), dtype=np.float32), warm)
        del warm

        state = st.init_streaming(model=cfg.model, chunk_size_sec=cfg.chunk_sec,
                                  language=cfg.language,
                                  endpointing_mode=cfg.endpointing)
        _emit(out_q, {"type": "ready", "engine": "qwen-mlx", "model": cfg.model,
                      "endpointing": cfg.endpointing,
                      "sample_rate": SAMPLE_RATE,
                      "warmup_sec": round(time.monotonic() - t0, 1)})
    except Exception as exc:  # 載入失敗要吵，不能降級成假資料
        _emit(out_q, {"type": "error", "code": "model_load_failed",
                      "message": f"{type(exc).__name__}: {exc}", "fatal": True})
        return

    step = int(SAMPLE_RATE * cfg.chunk_sec)
    buf = np.zeros(0, dtype=np.float32)
    audio_ms = 0            # 已經送進模型的音訊位置
    prev_stable = ""
    stable_end_ms = 0

    def flush(chunk: np.ndarray, final_flush: bool = False) -> None:
        nonlocal state, prev_stable, stable_end_ms, audio_ms
        chunk_ms = int(len(chunk) / SAMPLE_RATE * 1000)
        t0 = time.monotonic()
        try:
            if final_flush:
                if len(chunk):
                    state = st.feed_audio(chunk, state)
                state = st.finish_streaming(state)
            else:
                state = st.feed_audio(chunk, state)
        except Exception as exc:
            _emit(out_q, {"type": "error", "code": "asr_failed",
                          "message": f"{type(exc).__name__}: {exc}", "fatal": False})
            return
        audio_ms += chunk_ms
        infer_ms = (time.monotonic() - t0) * 1000

        stable = getattr(state, "stable_text", "") or ""
        text = getattr(state, "text", "") or ""

        # 模型會回頭改寫已經「穩定」的文字。天真地用 startswith 判斷，一旦改寫就整段
        # 重發，逐字稿會出現大量重複（WER 的插入錯誤）。改用最長共同前綴取差集，
        # 而且被改掉的部分要送 revise 事件——靜默改寫也是靜默失敗。
        common = _common_prefix_len(prev_stable, stable)
        if common < len(prev_stable):
            _emit(out_q, {"type": "revise", "from_char": common,
                          "dropped": prev_stable[common:],
                          "text": stable[common:], "end_ms": audio_ms})
        new_stable = stable[common:]
        prev_stable = stable

        if new_stable.strip():
            _emit(out_q, {"type": "final", "text": new_stable.strip(), "speaker": "spk_1",
                          "start_ms": stable_end_ms, "end_ms": audio_ms,
                          "infer_ms": round(infer_ms)})
            stable_end_ms = audio_ms

        tail = text[len(stable):] if text.startswith(stable) else text
        if tail.strip():
            _emit(out_q, {"type": "partial", "text": tail.strip(), "speaker": "spk_1",
                          "start_ms": stable_end_ms, "end_ms": audio_ms,
                          "infer_ms": round(infer_ms)})
        elif not new_stable.strip():
            # 沒有任何文字產出：講清楚是靜音還是模型吐不出東西
            rms = float(np.sqrt(np.mean(chunk**2))) if len(chunk) else 0.0
            _emit(out_q, {"type": "no_speech", "start_ms": audio_ms - chunk_ms,
                          "end_ms": audio_ms, "rms": round(rms, 5),
                          "reason": "silence" if rms < SILENCE_RMS else "no_output"})

    while True:
        item = audio_q.get()
        if item is None:  # 收工
            if len(buf):
                flush(buf, final_flush=True)
            else:
                flush(np.zeros(0, dtype=np.float32), final_flush=True)
            # done 帶上完整逐字稿：final 是增量、revise 會回頭改，重建全文很容易出錯，
            # 評測直接用這份權威版本。
            _emit(out_q, {"type": "done", "audio_ms": audio_ms,
                          "text": (getattr(state, "text", "") or "").strip()})
            return
        buf = np.concatenate([buf, item])
        while len(buf) >= step:
            flush(buf[:step])
            buf = buf[step:]


def start(cfg: WorkerConfig) -> tuple[mp.Process, mp.Queue, mp.Queue]:
    """spawn 一個 worker process，回傳 (process, audio_queue, event_queue)。

    一定要 spawn 不能 fork：MLX/Metal 的狀態 fork 過去會壞掉。
    """
    ctx = mp.get_context("spawn")
    # audio queue 有上限：塞爆代表推論追不上，這時要吵，不是無限長胖到把記憶體吃光
    # （舊版三個 queue 全部沒有 maxsize）。
    audio_q: mp.Queue = ctx.Queue(maxsize=512)  # 512 * 100ms ≈ 51 秒緩衝
    out_q: mp.Queue = ctx.Queue()
    proc = ctx.Process(target=run, args=(cfg, audio_q, out_q), daemon=True)
    proc.start()
    return proc, audio_q, out_q


def pcm_to_float(raw: bytes) -> np.ndarray:
    return np.frombuffer(raw, dtype=np.int16).astype(np.float32) / 32768.0
