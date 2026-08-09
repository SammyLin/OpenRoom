"""把各模組的 selfcheck 收成一個 `pytest` 指令。

邏輯本身寫在模組裡的 `_selfcheck()`，因為那樣 `python -m eval.corpus selfcheck`
在沒裝 pytest 的環境也跑得動。這裡只是入口。
"""

import asyncio

from eval import corpus, feed, metrics


def test_corpus_vtt_parsing():
    corpus._selfcheck()


def test_metrics():
    metrics._selfcheck()


def test_feeder_against_stub_server():
    """feeder 對著照協定實作的 stub server 跑一遍，含真實時間節奏與延遲計算。"""
    asyncio.run(feed._selfcheck())


def test_analyst():
    """JSON 解析、觸發節流，以及取消時 CLI process 有沒有跟著死。"""
    from openroom import analyst

    analyst._selfcheck()


def test_tolerant_merge():
    """標點不同的邊界重複要合掉；沒有重疊的不准亂動。"""
    from openroom.asr_worker import _tolerant_append

    orig = lambda c, a, lang: (c + a) if lang == "zh" else f"{c} {a}"
    m = lambda c, a, lang="zh": _tolerant_append(c, a, lang, orig)

    assert m("在三月。", "月中的。時候") == "在三月中的。時候"   # 標點卡在中間也要接得起來
    assert m("聽", "聽到謠言。") == "聽到謠言。"
    assert m("今天天氣", "很好") == "今天天氣很好"              # 沒重疊就原樣
    assert m("hey everyone welcome.", "welcome to this", "en") == "hey everyone welcome to this"


def test_common_prefix_delta():
    """模型改寫已穩定文字時，只能吐出差集，不能整段重發。"""
    from openroom.asr_worker import _common_prefix_len

    assert _common_prefix_len("hello world", "hello there") == 6
    assert _common_prefix_len("", "abc") == 0
    assert _common_prefix_len("abc", "abc") == 3
    # 舊寫法用 startswith 判斷，這個情境會整段重發造成逐字稿重複
    prev, now = "we have a full agenda", "we have a full agenda item"
    assert now[_common_prefix_len(prev, now):] == " item"
