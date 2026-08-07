"""WS server，實作 ``docs/protocol.md``。

單機工具，所以沒有 FastAPI、沒有 nginx、沒有 CORS、沒有 JWT——一個 websockets server
就夠了。舊版一半的複雜度來自那些「以後也許要」的東西。

這裡只做三件事，而且都不准靜默失敗：

1. 收音、寫檔（**先證明收得到音**，這是舊版死掉的地方）
2. 把 PCM 丟給另一個 process 的 ASR，自己絕不等推論
3. 把 worker 的事件轉發給前端，包含 ``no_speech`` / ``gap`` / ``error``
"""

from __future__ import annotations

import argparse
import asyncio
import json
import queue
import struct
import sys
import time
from pathlib import Path

import websockets

from .asr_worker import CHUNK_SEC, WorkerConfig, pcm_to_float, start

HEADER = struct.Struct(">II")  # seq, audio_ts_ms
RUNS = Path(__file__).resolve().parent.parent / "runs"


class Session:
    """一場會議。單機工具，一次只有一場。"""

    def __init__(self, meeting_id: str, cfg: WorkerConfig, record_dir: Path):
        self.meeting_id = meeting_id
        self.cfg = cfg
        self.record_dir = record_dir
        self.expected_seq = 0
        self.bytes_in = 0
        self.dropped = 0
        self.proc = self.audio_q = self.out_q = None
        self._raw = None

    def open(self):
        self.record_dir.mkdir(parents=True, exist_ok=True)
        self._raw = (self.record_dir / "audio.raw").open("wb")
        self.proc, self.audio_q, self.out_q = start(self.cfg)

    def close(self):
        if self.audio_q is not None:
            try:
                self.audio_q.put_nowait(None)
            except queue.Full:
                pass
        if self._raw:
            self._raw.close()

    def feed(self, seq: int, pcm: bytes) -> dict | None:
        """回傳需要送給 client 的 gap 事件，沒有就 None。"""
        gap = None
        if seq != self.expected_seq:
            lost = (seq - self.expected_seq) * 100
            gap = {"type": "gap", "expected_seq": self.expected_seq,
                   "got_seq": seq, "lost_ms": max(0, lost)}
        self.expected_seq = seq + 1
        self.bytes_in += len(pcm)
        self._raw.write(pcm)
        try:
            self.audio_q.put_nowait(pcm_to_float(pcm))
        except queue.Full:
            # 推論追不上。丟最新的一包並且明講——舊版是靜默丟棄。
            self.dropped += 1
            return {"type": "gap", "expected_seq": seq, "got_seq": seq,
                    "lost_ms": 100, "reason": "asr_backpressure"}
        return gap


async def handle(ws, cfg: WorkerConfig, runs_dir: Path):
    meeting_id = ws.request.path.rsplit("/", 1)[-1] or "default"
    stamp = time.strftime("%Y%m%d-%H%M%S")
    session: Session | None = None
    pump: asyncio.Task | None = None
    print(f"[{meeting_id}] 連線")

    async def pump_events():
        """worker 的 mp.Queue 是阻塞式的，用 to_thread 橋接，不要卡住 event loop。

        舊版把 DB 寫入用 ``run_coroutine_threadsafe(...).result()`` 直接阻塞
        event loop（``store.py:436``），這裡不重蹈。
        """
        loop = asyncio.get_running_loop()
        while True:
            event = await loop.run_in_executor(None, session.out_q.get)
            await ws.send(json.dumps(event, ensure_ascii=False))
            if event.get("type") == "error" and event.get("fatal"):
                return
            if event.get("type") == "done":
                return

    try:
        async for message in ws:
            if isinstance(message, str):
                data = json.loads(message)
                kind = data.get("type")
                if kind == "start":
                    if session is not None:
                        await ws.send(json.dumps({"type": "error", "code": "already_started",
                                                  "message": "重複的 start", "fatal": False}))
                        continue
                    session = Session(meeting_id, cfg, runs_dir / f"{stamp}-{meeting_id}")
                    session.open()
                    # ready 由 worker 預熱完才發出——冷啟動要 46 秒，提早說 ready
                    # 等於叫 client 把開場白送進黑洞。
                    first = await asyncio.get_running_loop().run_in_executor(
                        None, session.out_q.get)
                    await ws.send(json.dumps(first, ensure_ascii=False))
                    if first.get("type") != "ready":
                        break
                    print(f"[{meeting_id}] ready（預熱 {first.get('warmup_sec')} 秒）")
                    pump = asyncio.create_task(pump_events())
                elif kind == "stop":
                    break
                continue

            if session is None:
                # 舊版在這裡靜默丟棄，是「不會收音」的成因之一
                await ws.send(json.dumps({
                    "type": "error", "code": "no_start",
                    "message": "音訊在 start 之前送達，已丟棄", "fatal": False}))
                continue

            seq, _ts = HEADER.unpack(message[: HEADER.size])
            gap = session.feed(seq, message[HEADER.size :])
            if gap:
                await ws.send(json.dumps(gap))
    except websockets.ConnectionClosed:
        print(f"[{meeting_id}] client 斷線")
    finally:
        if session:
            session.close()
            if pump:
                try:
                    await asyncio.wait_for(pump, timeout=30)
                except (asyncio.TimeoutError, websockets.ConnectionClosed):
                    pump.cancel()
            print(f"[{meeting_id}] 結束：收到 {session.bytes_in / 32000:.1f} 秒音訊，"
                  f"丟棄 {session.dropped} 幀 → {session.record_dir}")


async def serve(host: str, port: int, cfg: WorkerConfig, runs_dir: Path):
    async with websockets.serve(lambda ws: handle(ws, cfg, runs_dir), host, port,
                                max_size=None):
        print(f"huddle server → ws://{host}:{port}/ws/{{meeting_id}}")
        print(f"模型 {cfg.model}，語言 {cfg.language or '自動'}，錄音寫到 {runs_dir}")
        await asyncio.Future()


def main(argv: list[str] | None = None) -> int:
    ap = argparse.ArgumentParser(prog="huddle.server")
    ap.add_argument("--host", default="127.0.0.1")
    ap.add_argument("--port", type=int, default=8000)
    ap.add_argument("--model", default="Qwen/Qwen3-ASR-0.6B")
    ap.add_argument("--language", default=None, help="en / zh…，不給就自動判斷")
    ap.add_argument("--chunk-sec", type=float, default=CHUNK_SEC)
    ap.add_argument("--endpointing", default="fixed", choices=["energy", "fixed"])
    ap.add_argument("--runs-dir", type=Path, default=RUNS)
    args = ap.parse_args(argv)

    cfg = WorkerConfig(model=args.model, language=args.language,
                       chunk_sec=args.chunk_sec, endpointing=args.endpointing)
    try:
        asyncio.run(serve(args.host, args.port, cfg, args.runs_dir))
    except KeyboardInterrupt:
        print("\n收工")
    return 0


if __name__ == "__main__":
    sys.exit(main())
