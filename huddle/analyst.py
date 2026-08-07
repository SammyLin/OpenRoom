"""即時分析層：一邊聽，一邊給補充資料與追問建議。

這是產品的重點，逐字稿只是原料。分析隨場合改變：

* ``interview``——判斷受訪者的答案對不對、漏了什麼，並建議下一個該問的問題。
* ``discussion``——把提到的專有名詞、工具、數字查清楚，補上背景。

LLM 走 ``claude`` CLI 的 print 模式。理由很現實：這台機器沒有 ANTHROPIC_API_KEY，
但 Claude Code 已經登入過，CLI 直接借用那份授權。代價是每次呼叫都要重付 CLI 啟動與
system prompt 的錢（實測約 6 秒、$0.12，快取命中後更低），所以觸發頻率必須節制。

**分析永遠不會擋到收音或逐字稿。** 呼叫在背景 task，同時只跑一個；上一輪還沒回來就
跳過這一輪，並且送出可見事件——不是靜靜地不做。
"""

from __future__ import annotations

import asyncio
import json
import time
from dataclasses import dataclass, field

# 一輪分析要看多少最近的逐字稿。太短沒有上下文，太長浪費 token 又拖慢。
CONTEXT_CHARS = 3_000
# 累積多少新字才值得再問一次。開會語速大約每分鐘 200–300 字。
TRIGGER_CHARS = 400
# 兩輪之間的最短間隔，避免話密的時候一直打 API。
MIN_INTERVAL_S = 25.0
CLI_TIMEOUT_S = 90.0

SCENARIOS = {
    "interview": {
        "label": "面試",
        "brief": (
            "你在旁聽一場面試。針對最近這段對話，判斷受訪者說的內容是否正確、"
            "有沒有含糊或跳過的地方，並建議面試官接下來該追問什麼。"
            "技術說法有錯就直接指出錯在哪。"
        ),
    },
    "discussion": {
        "label": "討論會議",
        "brief": (
            "你在旁聽一場工作會議。針對最近這段討論，補充與會者會需要的背景資料："
            "被提到的工具、專有名詞、版本、數字、前後脈絡。"
            "有不確定或值得查證的說法就標出來。"
        ),
    },
}

OUTPUT_CONTRACT = """\
只輸出 JSON，不要有其他文字、不要 markdown 圍欄。格式：
{"headline": "一句話說明這段在談什麼",
 "items": [{"kind": "fact|correction|context|risk", "text": "一到兩句"}],
 "questions": ["建議追問的問題"]}
items 最多 4 個，questions 最多 3 個。沒有內容就給空陣列。
用繁體中文，除了專有名詞。"""


@dataclass
class Insight:
    headline: str
    items: list[dict]
    questions: list[str]
    at_ms: int
    latency_ms: int


@dataclass
class Analyst:
    scenario: str = "discussion"
    model: str = "claude-sonnet-5"
    web_search: bool = True

    _transcript: list[str] = field(default_factory=list)
    _chars_since: int = 0
    _last_run: float = field(default_factory=lambda: 0.0)
    _running: bool = False

    def add_final(self, text: str) -> None:
        self._transcript.append(text)
        self._chars_since += len(text)

    def should_run(self, now: float) -> bool:
        if self._running or self._chars_since < TRIGGER_CHARS:
            return False
        return now - self._last_run >= MIN_INTERVAL_S

    def _prompt(self) -> str:
        joined = " ".join(self._transcript)[-CONTEXT_CHARS:]
        brief = SCENARIOS.get(self.scenario, SCENARIOS["discussion"])["brief"]
        extra = (
            "需要查證外部事實時可以用 WebSearch，但不要為了查而查。\n"
            if self.web_search
            else ""
        )
        return f"{brief}\n\n{extra}\n逐字稿（可能有辨識錯誤，請容錯理解）：\n---\n{joined}\n---\n\n{OUTPUT_CONTRACT}"

    async def run(self, audio_ms: int, emit) -> None:
        """跑一輪分析。emit 是 async callable，收 dict 事件。"""
        self._running = True
        self._chars_since = 0
        self._last_run = time.monotonic()
        t0 = time.monotonic()
        # 分析要好幾秒，期間 UI 必須知道「有東西在跑」，不然看起來像當掉
        await emit({"type": "insight_pending", "scenario": self.scenario, "at_ms": audio_ms})
        proc = None
        try:
            # nice：claude CLI 是很重的 node process，實測會把 ASR worker 的 CPU 吃光，
            # 單次推論從 0.37 秒被拖到 54 秒，音訊佇列塞爆開始丟包。分析可以慢，
            # 收音不能停，所以分析永遠排在後面。
            cmd = ["nice", "-n", "15", "claude", "-p", self._prompt(),
                   "--model", self.model, "--output-format", "json"]
            if self.web_search:
                cmd += ["--allowed-tools", "WebSearch"]
            proc = await asyncio.create_subprocess_exec(
                *cmd, stdout=asyncio.subprocess.PIPE, stderr=asyncio.subprocess.PIPE
            )
            try:
                out, err = await asyncio.wait_for(proc.communicate(), timeout=CLI_TIMEOUT_S)
            except asyncio.TimeoutError:
                proc.kill()
                await emit({"type": "insight_error", "code": "llm_timeout",
                            "message": f"分析超過 {CLI_TIMEOUT_S:.0f} 秒沒回應"})
                return

            if proc.returncode != 0:
                await emit({"type": "insight_error", "code": "llm_failed",
                            "message": (err.decode(errors="replace") or "claude CLI 失敗")[:300]})
                return

            insight = _parse(out.decode(errors="replace"))
            if insight is None:
                await emit({"type": "insight_error", "code": "llm_bad_output",
                            "message": "模型沒有回傳可解析的 JSON"})
                return

            await emit({
                "type": "insight",
                "scenario": self.scenario,
                "headline": insight.headline,
                "items": insight.items,
                "questions": insight.questions,
                "at_ms": audio_ms,
                "latency_ms": round((time.monotonic() - t0) * 1000),
            })
        finally:
            self._running = False
            # 這一輪被取消（會議結束）時，claude CLI 是個獨立的重量級 process，
            # 不殺它會在收工後繼續吃 CPU。
            if proc is not None and proc.returncode is None:
                proc.kill()


def _parse(raw: str) -> Insight | None:
    """claude --output-format json 會把回覆包在 result 欄位裡。"""
    try:
        envelope = json.loads(raw)
    except json.JSONDecodeError:
        return None
    body = envelope.get("result") if isinstance(envelope, dict) else None
    if not isinstance(body, str):
        return None
    # 模型偶爾還是會加圍欄，剝掉再解析
    body = body.strip()
    if body.startswith("```"):
        body = body.split("\n", 1)[-1].rsplit("```", 1)[0]
    start, end = body.find("{"), body.rfind("}")
    if start < 0 or end <= start:
        return None
    try:
        data = json.loads(body[start : end + 1])
    except json.JSONDecodeError:
        return None
    return Insight(
        headline=str(data.get("headline", "")).strip(),
        items=[i for i in data.get("items", []) if isinstance(i, dict) and i.get("text")][:4],
        questions=[str(q) for q in data.get("questions", []) if str(q).strip()][:3],
        at_ms=0,
        latency_ms=0,
    )


def _selfcheck() -> None:
    envelope = json.dumps({"result": '```json\n{"headline":"談 CI 快取","items":'
                                     '[{"kind":"context","text":"GitLab 的 cache key"}],'
                                     '"questions":["快取失效怎麼處理？"]}\n```'})
    got = _parse(envelope)
    assert got is not None and got.headline == "談 CI 快取", got
    assert got.items[0]["kind"] == "context" and len(got.questions) == 1, got
    assert _parse("not json") is None
    assert _parse(json.dumps({"result": "模型忘了給 JSON"})) is None

    a = Analyst()
    assert not a.should_run(1000.0)                  # 還沒有任何逐字稿
    a.add_final("x" * (TRIGGER_CHARS + 1))
    assert a.should_run(1000.0)                      # 累積夠了
    a._running = True
    assert not a.should_run(1000.0)                  # 上一輪還在跑就跳過

    asyncio.run(_cancel_check())
    print("selfcheck ok")


async def _cancel_check() -> None:
    """會議結束時取消這一輪分析，CLI process 必須跟著死。

    用 ``sleep 60`` 假裝 claude CLI，才不用真的花錢呼叫模型。
    """
    real = asyncio.create_subprocess_exec
    spawned = []

    async def fake(*cmd, **kw):
        proc = await real("sleep", "60", **kw)
        spawned.append(proc)
        return proc

    asyncio.create_subprocess_exec = fake
    try:
        task = asyncio.create_task(Analyst().run(0, lambda _e: asyncio.sleep(0)))
        await asyncio.sleep(0.2)
        task.cancel()
        await asyncio.gather(task, return_exceptions=True)
    finally:
        asyncio.create_subprocess_exec = real

    assert spawned, "沒有起 process"
    await spawned[0].wait()
    assert spawned[0].returncode == -9, spawned[0].returncode  # SIGKILL


if __name__ == "__main__":
    _selfcheck()
