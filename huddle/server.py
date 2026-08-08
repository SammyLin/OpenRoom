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

from .analyst import CLI_TIMEOUT_S, SCENARIOS, Analyst
from .asr_worker import CHUNK_SEC, WorkerConfig, pcm_to_float, start

HEADER = struct.Struct(">II")  # seq, audio_ts_ms
RUNS = Path(__file__).resolve().parent.parent / "runs"
# ASR 落後超過這麼多毫秒就別再跑分析——先把逐字稿追上，補充資料可以等
BACKLOG_SKIP_MS = 6_000


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
        self._events = None
        self._t0 = time.monotonic()

    def open(self):
        self.record_dir.mkdir(parents=True, exist_ok=True)
        self._raw = (self.record_dir / "audio.raw").open("wb")
        self._events = (self.record_dir / "events.jsonl").open("w", encoding="utf-8")
        self.proc, self.audio_q, self.out_q = start(self.cfg)

    def log(self, event: dict) -> None:
        """每一個送給 client 的事件都留一份。

        不落地就沒得標註 insight 品質，也沒得回頭看「那句話當時是怎麼斷的」。
        用 jsonl 不用 SQLite：單機、一次一場、寫完只讀一次，schema 跟 migration
        都是為不存在的問題付錢。
        """
        if self._events is None:
            return
        line = {"_wall_ms": round((time.monotonic() - self._t0) * 1000), **event}
        self._events.write(json.dumps(line, ensure_ascii=False) + "\n")
        self._events.flush()  # 會議中途看得到，而且當掉不會整份不見
        if event.get("type") == "done" and event.get("text"):
            (self.record_dir / "transcript.txt").write_text(
                event["text"] + "\n", encoding="utf-8")

    def close(self):
        if self.audio_q is not None:
            try:
                self.audio_q.put_nowait(None)
            except queue.Full:
                pass
        if self._raw:
            self._raw.close()

    def close_log(self):
        """事件檔要等 pump 排空才能關——``done`` 是最後一個事件，它比 ``close()`` 晚到。"""
        if self._events:
            self._events.close()
            self._events = None

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


async def handle(ws, cfg: WorkerConfig, runs_dir: Path, default_scenario: str,
                 llm_model: str, web_search: bool):
    meeting_id = ws.request.path.rsplit("/", 1)[-1] or "default"
    stamp = time.strftime("%Y%m%d-%H%M%S")
    session: Session | None = None
    pump: asyncio.Task | None = None
    insight: asyncio.Task | None = None
    # 量 ASR 的時候不該每跑一次就付一次 LLM 的錢，所以分析可以整個關掉
    analyst = (Analyst(scenario=default_scenario, model=llm_model, web_search=web_search)
               if llm_model else None)
    print(f"[{meeting_id}] 連線")

    async def send(event: dict) -> None:
        """唯一的出口。所有事件都走這裡，才不會有哪條路徑漏記。"""
        if session is not None:
            session.log(event)
        await ws.send(json.dumps(event, ensure_ascii=False))

    async def pump_events():
        """worker 的 mp.Queue 是阻塞式的，用 to_thread 橋接，不要卡住 event loop。

        舊版把 DB 寫入用 ``run_coroutine_threadsafe(...).result()`` 直接阻塞
        event loop（``store.py:436``），這裡不重蹈。分析同理：它是背景 task，
        永遠不擋逐字稿。
        """
        nonlocal insight
        loop = asyncio.get_running_loop()
        audio_ms = 0
        while True:
            event = await loop.run_in_executor(None, session.out_q.get)
            await send(event)

            if event.get("type") == "final" and analyst:
                audio_ms = event.get("end_ms", audio_ms)
                analyst.add_final(event.get("text", ""))
                if analyst.should_run(time.monotonic()):
                    # 第二層保險：ASR 已經在落後就不要再加負擔。跳過要講出來，
                    # 不能靜靜地不分析——那又變成舊版那種查不出原因的沉默。
                    # mp.Queue.qsize() 在 macOS 會丟 NotImplementedError，所以直接用
                    # 「收到的音訊」減「ASR 已處理的音訊」算積壓，一樣準而且不用問佇列。
                    backlog_ms = session.bytes_in / 32 - audio_ms
                    if backlog_ms > BACKLOG_SKIP_MS:
                        await send({"type": "insight_error", "code": "asr_behind",
                                    "message": f"ASR 落後 {backlog_ms / 1000:.0f} 秒，這輪分析跳過"})
                    else:
                        insight = asyncio.create_task(analyst.run(audio_ms, send))

            if event.get("type") == "error" and event.get("fatal"):
                return
            if event.get("type") == "done":
                # 收工前把剩下的內容做最後一輪分析，否則最後幾分鐘沒有補充資料
                if analyst and analyst._chars_since > 0 and not analyst._running:
                    await analyst.run(audio_ms, send)
                return

    try:
        async for message in ws:
            if isinstance(message, str):
                data = json.loads(message)
                kind = data.get("type")
                if kind == "start":
                    # 場合決定分析怎麼做：面試看答案對錯，討論會議補背景資料
                    if analyst and data.get("scenario") in SCENARIOS:
                        analyst.scenario = data["scenario"]
                    if session is not None:
                        await send({"type": "error", "code": "already_started",
                                    "message": "重複的 start", "fatal": False})
                        continue
                    session = Session(meeting_id, cfg, runs_dir / f"{stamp}-{meeting_id}")
                    session.open()
                    # ready 由 worker 預熱完才發出——冷啟動要 46 秒，提早說 ready
                    # 等於叫 client 把開場白送進黑洞。
                    first = await asyncio.get_running_loop().run_in_executor(
                        None, session.out_q.get)
                    await send(first)
                    if first.get("type") != "ready":
                        break
                    print(f"[{meeting_id}] ready（預熱 {first.get('warmup_sec')} 秒）")
                    pump = asyncio.create_task(pump_events())
                elif kind == "stop":
                    break
                continue

            if session is None:
                # 舊版在這裡靜默丟棄，是「不會收音」的成因之一
                await send({"type": "error", "code": "no_start",
                            "message": "音訊在 start 之前送達，已丟棄", "fatal": False})
                continue

            seq, _ts = HEADER.unpack(message[: HEADER.size])
            gap = session.feed(seq, message[HEADER.size :])
            if gap:
                await send(gap)
    except websockets.ConnectionClosed:
        print(f"[{meeting_id}] client 斷線")
    finally:
        # 分析比連線活得久：CLI 還在跑的時候 client 就斷了，回來 emit 會往關掉的
        # socket 送，變成沒人接的 task exception。收工就取消，並且講出來。
        if insight and not insight.done():
            insight.cancel()
            print(f"[{meeting_id}] 連線已結束，捨棄一輪還在跑的分析")
        if session:
            session.close()
            if pump:
                try:
                    # 收工那輪分析是在 done 之後才開始的，等的時間必須蓋得住 CLI 的
                    # timeout。之前寫死 30 秒，比分析的 90 秒短，最後一輪一定被砍掉
                    # ——錢付了，結果丟掉，會議最後幾分鐘沒有補充資料。
                    await asyncio.wait_for(pump, timeout=CLI_TIMEOUT_S + 15)
                except (asyncio.TimeoutError, websockets.ConnectionClosed):
                    pump.cancel()
                    # 砍掉要講出來。前端只在 insight / insight_error / done 收手，
                    # 沒有這個事件它會一直停在「分析中」。
                    try:
                        await send({"type": "insight_error", "code": "cut_short",
                                    "message": "會議結束時最後一輪分析還沒回來，已取消"})
                    except websockets.ConnectionClosed:
                        pass
            session.close_log()
            print(f"[{meeting_id}] 結束：收到 {session.bytes_in / 32000:.1f} 秒音訊，"
                  f"丟棄 {session.dropped} 幀 → {session.record_dir}")


async def serve(host: str, port: int, cfg: WorkerConfig, runs_dir: Path,
                scenario: str, llm_model: str, web_search: bool):
    handler = lambda ws: handle(ws, cfg, runs_dir, scenario, llm_model, web_search)
    async with websockets.serve(handler, host, port, max_size=None):
        print(f"huddle server → ws://{host}:{port}/ws/{{meeting_id}}")
        print(f"ASR {cfg.model}，語言 {cfg.language or '自動'}，錄音寫到 {runs_dir}")
        print(f"分析 {llm_model}，場合預設 {SCENARIOS[scenario]['label']}"
              f"，網路查證 {'開' if web_search else '關'}" if llm_model else "分析：關閉")
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
    ap.add_argument("--scenario", default="discussion", choices=sorted(SCENARIOS))
    ap.add_argument("--llm-model", default="claude-sonnet-5")
    ap.add_argument("--no-analyst", action="store_true",
                    help="完全關掉分析層（量 ASR 用，免得每跑一次就付一次 LLM 的錢）")
    ap.add_argument("--no-web-search", action="store_true",
                    help="關掉分析時的網路查證")
    args = ap.parse_args(argv)

    cfg = WorkerConfig(model=args.model, language=args.language,
                       chunk_sec=args.chunk_sec, endpointing=args.endpointing)
    try:
        asyncio.run(serve(args.host, args.port, cfg, args.runs_dir, args.scenario,
                          "" if args.no_analyst else args.llm_model,
                          not args.no_web_search))
    except KeyboardInterrupt:
        print("\n收工")
    return 0


if __name__ == "__main__":
    sys.exit(main())
