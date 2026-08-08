"""pyannote 講者分離——**跑在自己的 process**，而且刻意跑得斷斷續續。

pyannote 不是串流模型，一次只能對一整段音訊做分群。兩種做法只有一種可用：

* 只看最近 30 秒的視窗：便宜，但每個視窗各自分群，``SPEAKER_00`` 在前後視窗不是
  同一個人，會議中標籤一直換，等於沒有標。
* 對「目前為止的整段音訊」重跑：分群看得到全場，標籤前後一致。代價是成本隨會議
  長度線性上升——實測 RTF 0.086（M 系列 MPS），30 分鐘的會議一次要跑 2.6 分鐘。

選第二種，然後用**工作週期**壓住成本：跑完一次就休息 ``IDLE_RATIO`` 倍的時間。
ASR 跟 diarization 搶的是同一顆 GPU，而 ``docs/measurements.md`` 已經量過一次：
有東西把 GPU 吃滿的時候，單次 ASR 推論從 0.37 秒掉到 54 秒，音訊佇列直接塞爆。
**逐字稿不能停，講者標籤可以晚到。**

代價要講明白：講者標籤是**回填**的，不是即時的。舊 PRD 那條「講者切換辨識延遲
< 2 秒」在這個架構下做不到，也不值得為它換掉逐字稿的即時性。
"""

from __future__ import annotations

import multiprocessing as mp
import os
import queue
import time
from dataclasses import dataclass

import numpy as np

SAMPLE_RATE = 16_000
MODEL_ID = "pyannote/speaker-diarization-community-1"
# 累積這麼多新音訊才值得重跑一次。太短的新內容改不了分群結果。
MIN_NEW_SEC = 20.0
# 跑完休息 = 這次花掉的時間 × 這個倍數。這個值是量出來的，不是猜的：
# 倍數 3（吃 25% wall time）→ partial P95 1832 ms，**gate 800 ms 直接 FAIL**；
# 倍數 8（吃 11%）→ partial P95 702 ms，過。見 docs/measurements.md。
IDLE_RATIO = 8.0
MIN_IDLE_SEC = 15.0


@dataclass
class DiarizeConfig:
    model: str = MODEL_ID
    min_new_sec: float = MIN_NEW_SEC
    idle_ratio: float = IDLE_RATIO


def _emit(out: mp.Queue, event: dict) -> None:
    try:
        out.put_nowait(event)
    except queue.Full:  # pragma: no cover - out queue 沒有上限
        pass


def _load(cfg: DiarizeConfig, out_q: mp.Queue):
    """載入 pipeline。失敗一定要吵——沒有講者標籤是缺陷，不是可以靜靜跳過的事。"""
    try:
        import torch
        from pyannote.audio import Pipeline
    except ImportError as exc:
        _emit(out_q, {"type": "speaker_error", "code": "pyannote_missing",
                      "message": f"載入 pyannote.audio 失敗：{exc}"})
        return None
    if not (os.environ.get("HF_TOKEN") or os.environ.get("HUGGINGFACE_HUB_TOKEN")):
        # 這是 gated repo，沒 token 只會拿到 401。與其等它失敗，不如先講清楚。
        _emit(out_q, {"type": "speaker_error", "code": "hf_token_missing",
                      "message": "沒有 HF_TOKEN，pyannote 模型下載不了（gated repo）"})
        return None
    try:
        pipeline = Pipeline.from_pretrained(cfg.model)
        pipeline.to(torch.device("mps" if torch.backends.mps.is_available() else "cpu"))
        return pipeline
    except Exception as exc:
        _emit(out_q, {"type": "speaker_error", "code": "model_load_failed",
                      "message": f"{type(exc).__name__}: {exc}"})
        return None


def _turns(result) -> list[dict]:
    out: list[dict] = []
    for segment, _track, label in result.speaker_diarization.itertracks(yield_label=True):
        start, end = int(segment.start * 1000), int(segment.end * 1000)
        if end - start < 200:  # 0.2 秒以下的碎片是換手瞬間的雜訊，標了只會閃
            continue
        if out and out[-1]["speaker"] == label and start - out[-1]["end_ms"] < 400:
            out[-1]["end_ms"] = end          # 同一人被切開的相鄰段落接回去
        else:
            out.append({"speaker": label, "start_ms": start, "end_ms": end})
    return out


def run(cfg: DiarizeConfig, audio_q: mp.Queue, out_q: mp.Queue) -> None:
    """只從 audio_q 讀 PCM，只往 out_q 寫事件。"""
    import torch

    pipeline = _load(cfg, out_q)
    if pipeline is None:
        _emit(out_q, {"type": "speaker_done"})
        return
    _emit(out_q, {"type": "speaker_ready", "model": cfg.model})

    audio = np.zeros(0, dtype=np.float32)
    last_run_end = 0            # 上次分析涵蓋到哪裡（samples）
    next_run_at = 0.0           # 工作週期：在這個時間點之前不准再跑
    stopping = False

    while True:
        try:
            item = audio_q.get(timeout=1.0)
            if item is None:
                stopping = True   # 收工前再跑最後一次，涵蓋整場
            else:
                audio = np.concatenate([audio, item])
        except queue.Empty:
            pass

        new_sec = (len(audio) - last_run_end) / SAMPLE_RATE
        if not stopping:
            if new_sec < cfg.min_new_sec or time.monotonic() < next_run_at:
                continue
        elif len(audio) == 0:
            break

        t0 = time.monotonic()
        try:
            result = pipeline({"waveform": torch.from_numpy(audio).unsqueeze(0),
                               "sample_rate": SAMPLE_RATE})
        except Exception as exc:
            _emit(out_q, {"type": "speaker_error", "code": "diarize_failed",
                          "message": f"{type(exc).__name__}: {exc}"})
            if stopping:
                break
            next_run_at = time.monotonic() + MIN_IDLE_SEC
            continue
        infer_ms = (time.monotonic() - t0) * 1000
        last_run_end = len(audio)
        turns = _turns(result)
        _emit(out_q, {"type": "speaker_turns", "turns": turns,
                      "speakers": len({t["speaker"] for t in turns}),
                      "covers_ms": int(len(audio) / SAMPLE_RATE * 1000),
                      "infer_ms": round(infer_ms)})
        if stopping:
            break
        # 讓出 GPU：休息時間跟這次花掉的時間成正比，會議越長跑得越稀疏
        next_run_at = time.monotonic() + max(MIN_IDLE_SEC, infer_ms / 1000 * cfg.idle_ratio)

    # 明確收尾：server 端的 pump 靠這個事件結束，不然會卡在阻塞的 queue.get 上
    _emit(out_q, {"type": "speaker_done"})


def start(cfg: DiarizeConfig) -> tuple[mp.Process, mp.Queue, mp.Queue]:
    ctx = mp.get_context("spawn")
    # 跟 ASR 一樣有上限：塞爆代表 diarization 追不上，要吵，不是長胖到吃光記憶體
    audio_q: mp.Queue = ctx.Queue(maxsize=4096)   # 4096 * 100ms ≈ 6.8 分鐘
    out_q: mp.Queue = ctx.Queue()
    proc = ctx.Process(target=run, args=(cfg, audio_q, out_q), daemon=True)
    proc.start()
    return proc, audio_q, out_q


def _selfcheck() -> None:
    """_turns 的合併與過濾。跑模型要 GPU 跟 gated 權重，這裡只驗純邏輯。"""
    class Seg:
        def __init__(self, s, e): self.start, self.end = s, e

    class Fake:
        def __init__(self, rows): self._rows = rows
        @property
        def speaker_diarization(self): return self
        def itertracks(self, yield_label=True):
            return [(Seg(s, e), None, l) for s, e, l in self._rows]

    got = _turns(Fake([(0.0, 3.8, "A"), (3.8, 3.9, "B"), (3.9, 10.0, "A"), (11.0, 12.0, "A")]))
    assert [t["speaker"] for t in got] == ["A", "A"], got   # 0.1 秒的 B 是換手雜訊，丟掉
    assert got[0]["start_ms"] == 0 and got[0]["end_ms"] == 10_000, got  # 中間被切開的接回去
    assert got[1]["start_ms"] == 11_000, got                # 隔了 1 秒就是兩段

    two = _turns(Fake([(0.0, 5.0, "A"), (5.0, 9.0, "B")]))
    assert [t["speaker"] for t in two] == ["A", "B"], two   # 不同人不准合併
    print("selfcheck ok")


if __name__ == "__main__":
    _selfcheck()
