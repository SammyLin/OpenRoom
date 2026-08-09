"""即時分析層：一邊聽，一邊給補充資料與追問建議。

這是產品的重點，逐字稿只是原料。分析隨場合改變：

* ``interview``——判斷受訪者的答案對不對、漏了什麼，並建議下一個該問的問題。
* ``discussion``——把提到的專有名詞、工具、數字查清楚，補上背景。

LLM 預設走 ``claude`` CLI 的 print 模式。理由很現實：這台機器沒有 ANTHROPIC_API_KEY，
但 Claude Code 已經登入過，CLI 直接借用那份授權。代價是每次呼叫都要重付 CLI 啟動與
system prompt 的錢（實測約 6 秒、$0.12，快取命中後更低），所以觸發頻率必須節制。

provider 可以用 ``HUDDLE_LLM_PROVIDER`` 換掉：``claude-cli``（預設，行為完全不變）、
``cli``（另一支相容的 CLI，工具名走 ``HUDDLE_LLM_CLI``）、``anthropic-api``（直接打
Anthropic Messages API，要 ``ANTHROPIC_API_KEY``）、``ollama``（本地 Ollama 伺服器，
模型名走 ``HUDDLE_OLLAMA_MODEL``）。四個都一樣：失敗要吵，不准悄悄吐空結果。

**分析永遠不會擋到收音或逐字稿。** 呼叫在背景 task，同時只跑一個；上一輪還沒回來就
跳過這一輪，並且送出可見事件——不是靜靜地不做。
"""

from __future__ import annotations

import asyncio
import json
import os
import time
import urllib.error
import urllib.request
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
items 最多 4 個，questions 最多 3 個。**只講新的東西**：已經講過的背景、已經指出過的
辨識錯誤、已經問過的問題，一律不要再講一次。沒有新東西就把 items 跟 questions 都給
空陣列，這是正常結果，不是失敗。
用繁體中文，除了專有名詞。"""

# 記得前幾輪講過什麼。太少會重複，太多會吃掉逐字稿的上下文空間。
MEMORY_CHARS = 1_500


@dataclass
class Insight:
    headline: str
    items: list[dict]
    questions: list[str]
    at_ms: int
    latency_ms: int


class LLMTimeout(Exception):
    """provider 在時限內沒回應。"""


class LLMFailure(Exception):
    """provider 明確失敗——code/message 直接塞進 insight_error 事件，不准靜默吞掉。"""

    def __init__(self, code: str, message: str):
        super().__init__(message)
        self.code = code
        self.message = message


@dataclass
class Analyst:
    scenario: str = "discussion"
    model: str = "claude-sonnet-5"
    web_search: bool = True
    # 選 provider 走 HUDDLE_LLM_PROVIDER，預設 claude-cli 保留現有行為原封不動。
    provider: str = field(
        default_factory=lambda: os.environ.get("HUDDLE_LLM_PROVIDER", "claude-cli")
    )

    _transcript: list[str] = field(default_factory=list)
    # 講過的話要記得。實測 19 輪的會議裡，「marketplace 是集中發布」講了 13 次、
    # 「Chad 疑似辨識錯誤」講了 11 次——不是模型笨，是每輪都從零開始看逐字稿。
    _said: list[str] = field(default_factory=list)
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
        said = " / ".join(self._said)[-MEMORY_CHARS:]
        memory = f"\n你在這場會議已經講過這些，不要再講一次：\n---\n{said}\n---\n" if said else ""
        return (f"{brief}\n\n{extra}{memory}\n逐字稿（可能有辨識錯誤，請容錯理解）："
                f"\n---\n{joined}\n---\n\n{OUTPUT_CONTRACT}")

    async def run(self, audio_ms: int, emit) -> None:
        """跑一輪分析。emit 是 async callable，收 dict 事件。"""
        self._running = True
        self._chars_since = 0
        self._last_run = time.monotonic()
        t0 = time.monotonic()
        # 分析要好幾秒，期間 UI 必須知道「有東西在跑」，不然看起來像當掉
        await emit({"type": "insight_pending", "scenario": self.scenario, "at_ms": audio_ms})
        try:
            call = PROVIDERS.get(self.provider)
            if call is None:
                await emit({"type": "insight_error", "code": "llm_config",
                            "message": f"未知的 HUDDLE_LLM_PROVIDER：{self.provider}"})
                return
            try:
                body = await call(self._prompt(), self.model, self.web_search)
            except LLMTimeout:
                await emit({"type": "insight_error", "code": "llm_timeout",
                            "message": f"分析超過 {CLI_TIMEOUT_S:.0f} 秒沒回應"})
                return
            except LLMFailure as exc:
                await emit({"type": "insight_error", "code": exc.code,
                            "message": exc.message[:300]})
                return

            insight = _insight_from_text(body)
            if insight is None:
                await emit({"type": "insight_error", "code": "llm_bad_output",
                            "message": "模型沒有回傳可解析的 JSON"})
                return

            if not insight.items and not insight.questions:
                # 沒有新東西是正常結果。但也不能靜靜地什麼都不做——UI 得知道這輪跑完了。
                await emit({"type": "insight_none", "at_ms": audio_ms,
                            "latency_ms": round((time.monotonic() - t0) * 1000)})
                return

            self._said.append(insight.headline + "：" + "；".join(
                i["text"] for i in insight.items))
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


# ---------------------------------------------------------------------------
# Providers。簡單的函式分派就夠了，不需要 plugin registry。每個 provider 的合約都一樣：
# (prompt, model, web_search) -> 模型輸出的原始文字（body，尚未挖出裡面的 JSON insight）。
# 失敗一律 raise LLMTimeout / LLMFailure，run() 那邊會轉成看得到的 insight_error。
# ---------------------------------------------------------------------------

async def _run_cli(binary: str, prompt: str, model: str, web_search: bool) -> str:
    """跑一個相容 `claude -p ... --output-format json` 合約的 CLI，回傳模型輸出文字
    （已經拆開 envelope 的 result 欄位）。``claude-cli`` 與 ``cli``（HUDDLE_LLM_CLI
    指定 codex、gemini 之類的其他工具）都走這裡——假設對方也吃得下同一組 flag，這是
    「不要為了支援任何 CLI 就過度設計」的權衡。
    """
    cmd = ["nice", "-n", "15", binary, "-p", prompt, "--model", model, "--output-format", "json"]
    if web_search:
        cmd += ["--allowed-tools", "WebSearch"]
    proc = await asyncio.create_subprocess_exec(
        *cmd, stdout=asyncio.subprocess.PIPE, stderr=asyncio.subprocess.PIPE
    )
    try:
        try:
            out, err = await asyncio.wait_for(proc.communicate(), timeout=CLI_TIMEOUT_S)
        except asyncio.TimeoutError:
            raise LLMTimeout() from None
        if proc.returncode != 0:
            raise LLMFailure("llm_failed",
                              err.decode(errors="replace") or f"{binary} CLI 失敗")
    finally:
        # 這一輪被取消（會議結束）時，CLI 是個獨立的重量級 process，
        # 不殺它會在收工後繼續吃 CPU。
        if proc.returncode is None:
            proc.kill()

    raw = out.decode(errors="replace")
    try:
        envelope = json.loads(raw)
    except json.JSONDecodeError:
        raise LLMFailure("llm_bad_output", f"{binary} 沒有輸出可解析的 JSON") from None
    body = envelope.get("result") if isinstance(envelope, dict) else None
    if not isinstance(body, str):
        raise LLMFailure("llm_bad_output", f"{binary} 輸出缺少 result 欄位")
    return body


def _http_post_json(req: urllib.request.Request) -> dict:
    """ponytail: 阻塞呼叫，靠 asyncio.to_thread 丟到別的 thread，不擋 event loop。
    cancel 這顆 task 沒辦法真的中斷底層 socket——上限是 urlopen 自己的 timeout，
    跟 claude CLI 那邊 SIGKILL 就死的乾脆比起來是個已知限制。
    """
    with urllib.request.urlopen(req, timeout=CLI_TIMEOUT_S) as resp:
        return json.loads(resp.read().decode())


def _text_from_anthropic_response(data: dict) -> str:
    return "".join(b.get("text", "") for b in data.get("content", []) if b.get("type") == "text")


async def _call_anthropic_api(prompt: str, model: str, web_search: bool) -> str:
    """直接打 Anthropic Messages API。走 stdlib urllib，不為了一個 POST 引入 httpx。"""
    api_key = os.environ.get("ANTHROPIC_API_KEY")
    if not api_key:
        raise LLMFailure("llm_config", "ANTHROPIC_API_KEY 沒有設定")
    body: dict = {
        "model": model,
        "max_tokens": 1024,
        "messages": [{"role": "user", "content": prompt}],
    }
    if web_search:
        body["tools"] = [{"type": "web_search_20260209", "name": "web_search"}]
    req = urllib.request.Request(
        "https://api.anthropic.com/v1/messages",
        data=json.dumps(body).encode(),
        headers={
            "x-api-key": api_key,
            "anthropic-version": "2023-06-01",
            "content-type": "application/json",
        },
        method="POST",
    )
    try:
        data = await asyncio.to_thread(_http_post_json, req)
    except TimeoutError:
        raise LLMTimeout() from None
    except urllib.error.URLError as exc:
        raise LLMFailure("llm_failed", f"Anthropic API 呼叫失敗：{exc}") from exc

    if data.get("stop_reason") == "refusal":
        raise LLMFailure("llm_failed", "Anthropic API 拒絕了這次請求（refusal）")
    text = _text_from_anthropic_response(data)
    if not text:
        raise LLMFailure("llm_bad_output", "Anthropic API 沒有回傳文字內容")
    return text


def _text_from_ollama_response(data: dict) -> str:
    return data.get("response", "")


async def _call_ollama(prompt: str, model: str) -> str:
    """打本地 Ollama 伺服器的 /api/generate。"""
    host = os.environ.get("OLLAMA_HOST", "http://localhost:11434")
    body = {"model": model, "prompt": prompt, "stream": False}
    req = urllib.request.Request(
        f"{host.rstrip('/')}/api/generate",
        data=json.dumps(body).encode(),
        headers={"content-type": "application/json"},
        method="POST",
    )
    try:
        data = await asyncio.to_thread(_http_post_json, req)
    except TimeoutError:
        raise LLMTimeout() from None
    except urllib.error.URLError as exc:
        raise LLMFailure("llm_failed", f"Ollama 呼叫失敗（{host}）：{exc}") from exc

    text = _text_from_ollama_response(data)
    if not text:
        raise LLMFailure("llm_bad_output", "Ollama 沒有回傳文字內容")
    return text


PROVIDERS = {
    "claude-cli": lambda prompt, model, web_search: _run_cli("claude", prompt, model, web_search),
    "cli": lambda prompt, model, web_search: _run_cli(
        os.environ.get("HUDDLE_LLM_CLI", "claude"), prompt, model, web_search),
    "anthropic-api": _call_anthropic_api,
    "ollama": lambda prompt, model, web_search: _call_ollama(
        prompt, os.environ.get("HUDDLE_OLLAMA_MODEL", "llama3.1")),
}


def _insight_from_text(body: str) -> Insight | None:
    """從模型輸出的文字裡挖出 JSON insight。模型偶爾會加 markdown 圍欄，剝掉再解析。"""
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


def _parse(raw: str) -> Insight | None:
    """claude --output-format json（以及相容合約的 CLI）把回覆包在 result 欄位裡。

    只留給 selfcheck 用：正式路徑走 ``_run_cli``，envelope 拆解已經內建在裡面，
    ``run()`` 拿到的是已經拆開的 body。
    """
    try:
        envelope = json.loads(raw)
    except json.JSONDecodeError:
        return None
    body = envelope.get("result") if isinstance(envelope, dict) else None
    if not isinstance(body, str):
        return None
    return _insight_from_text(body)


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

    # 記憶：講過的話要進 prompt，否則每輪都重講一次背景
    b = Analyst()
    b.add_final("在講 marketplace")
    assert "你在這場會議已經講過這些" not in b._prompt()   # 第一輪沒有記憶可帶
    b._said.append("談 marketplace：更新一次就會 cascade 給所有人")
    assert "cascade 給所有人" in b._prompt(), b._prompt()

    # provider 選擇：預設 claude-cli，env var 可以換掉，換到不存在的名字要吵
    assert set(PROVIDERS) == {"claude-cli", "cli", "anthropic-api", "ollama"}
    assert Analyst().provider == "claude-cli"
    os.environ["HUDDLE_LLM_PROVIDER"] = "ollama"
    try:
        assert Analyst().provider == "ollama"
    finally:
        del os.environ["HUDDLE_LLM_PROVIDER"]

    # API/Ollama provider 的文字抽取邏輯——不用真的打網路也能測
    assert _text_from_anthropic_response(
        {"content": [{"type": "text", "text": "hi "}, {"type": "text", "text": "there"}]}
    ) == "hi there"
    assert _text_from_anthropic_response({"content": []}) == ""
    assert _text_from_ollama_response({"response": "hello"}) == "hello"
    assert _text_from_ollama_response({}) == ""

    asyncio.run(_cancel_check())
    asyncio.run(_unknown_provider_check())
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


async def _unknown_provider_check() -> None:
    """provider 設成沒人認得的名字，run() 要吵出來，不能默默什麼都不做。"""
    events: list[dict] = []

    async def emit(e):
        events.append(e)

    await Analyst(provider="not-a-real-provider").run(0, emit)
    codes = [e.get("code") for e in events if e.get("type") == "insight_error"]
    assert "llm_config" in codes, events


if __name__ == "__main__":
    _selfcheck()
