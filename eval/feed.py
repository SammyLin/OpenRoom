"""把音檔按**真實時間節奏**灌進 WS，量延遲。

這是整個 harness 的重點。離線批次跑模型量出來的延遲是假的——真實情況下，音訊是
一邊講一邊進來的，模型推論會跟後面進來的音訊搶資源。舊版就是死在這裡：final 轉錄
會擋住收音（``whisper_mlx.py:246-255``），越講越落後。只有按真實時間餵，才測得到。

``ffmpeg -re`` 負責節奏，而且順便吃掉任何輸入格式。音訊走的路徑跟未來的系統音訊
擷取完全一樣（同一份 ``docs/protocol.md``），所以測出來的數字算數。

延遲定義::

    latency = 事件抵達的 wall clock − 涵蓋該事件 end_ms 的那一幀送出的 wall clock

也就是「這句話講完之後，過多久看到字」。
"""

from __future__ import annotations

import argparse
import asyncio
import json
import shutil
import struct
import sys
import time
from dataclasses import dataclass, field
from pathlib import Path

from .metrics import percentile

SAMPLE_RATE = 16_000
CHUNK_MS = 100
CHUNK_BYTES = SAMPLE_RATE * 2 * CHUNK_MS // 1000  # 3200
HEADER = struct.Struct(">II")  # seq, audio_ts_ms

# 及格線（README 的表）
GATES = {"partial": 800.0, "final": 3000.0}


@dataclass
class Report:
    events: list[dict] = field(default_factory=list)
    latencies: dict[str, list[float]] = field(default_factory=dict)
    chunks_sent: int = 0
    audio_ms: int = 0
    wall_ms: float = 0.0

    def finals_text(self) -> str:
        """逐字稿。``done`` 帶的是權威全文（final 是增量、revise 會回頭改寫，
        自己重建容易出錯），沒有才退回串接 final。"""
        for e in reversed(self.events):
            if e.get("type") == "done" and e.get("text"):
                return e["text"]
        return "\n".join(
            e["text"] for e in self.events if e.get("type") == "final" and e.get("text")
        )

    def summary(self) -> str:
        lines = [
            f"送出 {self.chunks_sent} 幀 / {self.audio_ms / 1000:.1f} 秒音訊"
            f"（wall clock {self.wall_ms / 1000:.1f} 秒）",
        ]
        counts: dict[str, int] = {}
        for e in self.events:
            counts[e.get("type", "?")] = counts.get(e.get("type", "?"), 0) + 1
        lines.append("事件：" + (", ".join(f"{k}={v}" for k, v in sorted(counts.items())) or "無"))

        for kind in ("partial", "final"):
            vals = self.latencies.get(kind) or []
            if not vals:
                lines.append(f"{kind:8} 延遲：無樣本")
                continue
            p50 = percentile(vals, 50)
            p95 = percentile(vals, 95)
            gate = GATES[kind]
            mark = "PASS" if p95 < gate else "FAIL"
            lines.append(
                f"{kind:8} 延遲：P50 {p50:7.0f} ms   P95 {p95:7.0f} ms"
                f"   (gate < {gate:.0f} ms) {mark}   n={len(vals)}"
            )
        # 靜默失敗是舊版的死因，所以這幾類事件單獨拉出來講
        for kind in ("no_speech", "gap", "revise", "error"):
            n = counts.get(kind, 0)
            if n:
                lines.append(f"注意：{n} 個 {kind} 事件")
        return "\n".join(lines)

    def passed(self) -> bool:
        if any(e.get("type") == "error" for e in self.events):
            return False
        for kind, gate in GATES.items():
            vals = self.latencies.get(kind) or []
            if not vals or percentile(vals, 95) >= gate:
                return False
        return True


async def _read_events(ws, report: Report, t0: float, send_wall: list[float]) -> None:
    async for raw in ws:
        if isinstance(raw, bytes):
            continue
        try:
            event = json.loads(raw)
        except json.JSONDecodeError:
            print(f"收到非 JSON 訊息：{raw[:120]!r}", file=sys.stderr)
            continue
        now = time.monotonic()
        event["_arrival_ms"] = (now - t0) * 1000
        report.events.append(event)

        end_ms = event.get("end_ms")
        kind = event.get("type")
        if kind in GATES and isinstance(end_ms, (int, float)):
            # end_ms 是「不含」的結尾，所以涵蓋它的是前一幀：end_ms=2000 落在第 19 幀
            idx = (max(0, int(end_ms) - 1)) // CHUNK_MS
            if 0 <= idx < len(send_wall):
                latency = (now - send_wall[idx]) * 1000
                report.latencies.setdefault(kind, []).append(latency)
            else:
                print(
                    f"警告：{kind} 的 end_ms={end_ms} 超出已送出的音訊範圍"
                    f"（已送 {len(send_wall)} 幀），不列入延遲統計",
                    file=sys.stderr,
                )
        if kind == "error":
            print(f"server 回報錯誤：{event}", file=sys.stderr)


async def feed(
    audio: Path,
    ws_url: str,
    engine: str = "qwen-mlx",
    limit_sec: float | None = None,
    drain_sec: float = 10.0,
) -> Report:
    import websockets

    ffmpeg = shutil.which("ffmpeg")
    if not ffmpeg:
        raise RuntimeError("找不到 ffmpeg，請先 `brew install ffmpeg`")
    if not audio.exists():
        raise FileNotFoundError(audio)

    cmd = [
        ffmpeg, "-hide_banner", "-loglevel", "error",
        "-re",                      # ← 真實時間節奏，整個測量的根據
        "-i", str(audio),
        "-f", "s16le", "-ac", "1", "-ar", str(SAMPLE_RATE), "-",
    ]
    if limit_sec:
        cmd[7:7] = ["-t", str(limit_sec)]

    report = Report()
    send_wall: list[float] = []

    async with websockets.connect(ws_url, max_queue=None) as ws:
        await ws.send(json.dumps({
            "type": "start",
            "sample_rate": SAMPLE_RATE,
            "channels": 1,
            "format": "s16le",
            "source": "eval",
            "engine": engine,
        }))
        # 協定規定要等 ready。不等就送 = 舊版靜默丟音訊的重演。
        # 冷啟動要編譯 Metal kernel，實測第一次 ~46 秒，所以這裡等得比較久。
        try:
            first = json.loads(await asyncio.wait_for(ws.recv(), timeout=180))
        except asyncio.TimeoutError:
            raise RuntimeError("等 ready 等了 180 秒沒回應，server 沒照 docs/protocol.md 實作")
        if first.get("type") != "ready":
            raise RuntimeError(f"預期 ready，收到 {first}")

        t0 = time.monotonic()
        reader = asyncio.create_task(_read_events(ws, report, t0, send_wall))
        proc = await asyncio.create_subprocess_exec(
            *cmd, stdout=asyncio.subprocess.PIPE, stderr=asyncio.subprocess.PIPE
        )
        assert proc.stdout is not None

        seq = 0
        try:
            while True:
                pcm = await proc.stdout.readexactly(CHUNK_BYTES)
                send_wall.append(time.monotonic())
                await ws.send(HEADER.pack(seq, seq * CHUNK_MS) + pcm)
                seq += 1
        except asyncio.IncompleteReadError as exc:
            if exc.partial:  # 尾巴不足 100 ms，補零送完，別默默吞掉
                send_wall.append(time.monotonic())
                await ws.send(
                    HEADER.pack(seq, seq * CHUNK_MS)
                    + exc.partial.ljust(CHUNK_BYTES, b"\x00")
                )
                seq += 1

        await proc.wait()
        if proc.returncode not in (0, None):
            err = (await proc.stderr.read()).decode(errors="replace")
            raise RuntimeError(f"ffmpeg 失敗（exit {proc.returncode}）：{err[:500]}")

        report.chunks_sent = seq
        report.audio_ms = seq * CHUNK_MS
        await ws.send(json.dumps({"type": "stop"}))

        # 音訊送完之後，還在跑的推論需要時間吐完最後幾個 final
        try:
            await asyncio.wait_for(asyncio.shield(reader), timeout=drain_sec)
        except asyncio.TimeoutError:
            pass
        reader.cancel()
        report.wall_ms = (time.monotonic() - t0) * 1000

    return report


# ------------------------------------------------------------ selfcheck

async def _stub_server(host: str, port: int, ready: asyncio.Event) -> None:
    """照 docs/protocol.md 實作的最小 server，用來驗證 feeder 本身。

    收到音訊後固定延遲吐 partial / final，讓延遲計算有可預期的答案。
    """
    import websockets

    async def handler(ws):
        seen_start = False
        last_partial_ts = -1
        async for msg in ws:
            if isinstance(msg, str):
                data = json.loads(msg)
                if data.get("type") == "start":
                    seen_start = True
                    await ws.send(json.dumps({"type": "ready", "engine": "stub"}))
                elif data.get("type") == "stop":
                    break
                continue
            if not seen_start:
                await ws.send(json.dumps({
                    "type": "error", "code": "no_start",
                    "message": "音訊在 start 之前送達", "fatal": True,
                }))
                continue
            seq, ts = HEADER.unpack(msg[: HEADER.size])
            # 每 500 ms 一個 partial，每 1000 ms 一個 final
            if ts // 500 != last_partial_ts // 500:
                await ws.send(json.dumps({
                    "type": "partial", "id": f"p{seq}", "text": f"partial {seq}",
                    "speaker": "spk_1", "start_ms": max(0, ts - 500), "end_ms": ts,
                    "confidence": 0.7,
                }))
            if ts and ts % 1000 == 0:
                await ws.send(json.dumps({
                    "type": "final", "id": f"f{seq}", "text": f"final {seq}",
                    "speaker": "spk_1", "start_ms": ts - 1000, "end_ms": ts,
                    "confidence": 0.9,
                }))
            last_partial_ts = ts

    async with websockets.serve(handler, host, port):
        ready.set()
        await asyncio.Event().wait()


async def _selfcheck() -> None:
    # feed() 上面就守了同一件事，這裡漏掉的話 ffmpeg 缺席會變成
    # `TypeError: expected str ... not NoneType`，指向 asyncio 內部而不是缺工具。
    ffmpeg = shutil.which("ffmpeg")
    if not ffmpeg:
        raise RuntimeError("找不到 ffmpeg，請先 `brew install ffmpeg`")
    tmp = Path(__file__).resolve().parent.parent / "runs" / "_selfcheck"
    tmp.mkdir(parents=True, exist_ok=True)
    wav = tmp / "tone.wav"
    if not wav.exists():
        proc = await asyncio.create_subprocess_exec(
            ffmpeg, "-hide_banner", "-loglevel", "error", "-y",
            "-f", "lavfi", "-i", "sine=frequency=440:duration=3",
            "-ac", "1", "-ar", str(SAMPLE_RATE), "-c:a", "pcm_s16le", str(wav),
        )
        await proc.wait()

    ready = asyncio.Event()
    port = 8791
    server = asyncio.create_task(_stub_server("127.0.0.1", port, ready))
    await asyncio.wait_for(ready.wait(), timeout=10)
    try:
        report = await feed(wav, f"ws://127.0.0.1:{port}/ws/selfcheck",
                            engine="stub", drain_sec=2.0)
    finally:
        server.cancel()

    assert report.chunks_sent == 30, report.chunks_sent          # 3 秒 = 30 幀
    assert report.audio_ms == 3000, report.audio_ms
    # -re 保證 wall clock 不會比音訊短（快進的話延遲數字就沒意義了）
    assert report.wall_ms >= 2800, report.wall_ms
    assert len(report.latencies.get("partial", [])) >= 5, report.latencies
    assert len(report.latencies.get("final", [])) >= 2, report.latencies
    # stub 是立即回應，延遲應該是個位數毫秒等級
    assert percentile(report.latencies["final"], 95) < 200, report.latencies["final"]
    assert report.passed(), report.summary()
    assert "final" in report.finals_text()
    print(report.summary())
    print("selfcheck ok")


def main(argv: list[str] | None = None) -> int:
    ap = argparse.ArgumentParser(prog="eval.feed", description="按真實時間把音檔灌進 WS")
    ap.add_argument("audio", type=Path, nargs="?", help="音檔（任何 ffmpeg 讀得懂的格式）")
    ap.add_argument("--ws", default="ws://127.0.0.1:8000/ws/eval")
    ap.add_argument("--engine", default="qwen-mlx")
    ap.add_argument("--limit-sec", type=float, help="只餵前 N 秒")
    ap.add_argument("--drain-sec", type=float, default=10.0, help="送完後等最後幾個 final 的秒數")
    ap.add_argument("--out", type=Path, help="把逐字稿與事件寫到這個目錄")
    ap.add_argument("--selfcheck", action="store_true")
    args = ap.parse_args(argv)

    if args.selfcheck:
        asyncio.run(_selfcheck())
        return 0
    if not args.audio:
        ap.error("要給音檔，或用 --selfcheck")

    try:
        report = asyncio.run(
            feed(args.audio, args.ws, args.engine, args.limit_sec, args.drain_sec)
        )
    except (RuntimeError, FileNotFoundError, OSError) as exc:
        print(f"錯誤：{exc}", file=sys.stderr)
        return 1

    print(report.summary())
    out = args.out or (
        Path(__file__).resolve().parent.parent / "runs" / time.strftime("%Y%m%d-%H%M%S")
    )
    out.mkdir(parents=True, exist_ok=True)
    (out / "hypothesis.txt").write_text(report.finals_text() + "\n", encoding="utf-8")
    with (out / "events.jsonl").open("w", encoding="utf-8") as fh:
        for e in report.events:
            fh.write(json.dumps(e, ensure_ascii=False) + "\n")
    (out / "summary.txt").write_text(report.summary() + "\n", encoding="utf-8")
    print(f"\n輸出：{out}")
    return 0 if report.passed() else 1


if __name__ == "__main__":
    sys.exit(main())
