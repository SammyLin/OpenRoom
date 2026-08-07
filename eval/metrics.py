"""指標：WER / CER 與延遲百分位。

中英夾雜是這個產品的一級需求，所以斷詞不能只用空白切。慣例是中文算 CER（逐字），
英文算 WER（逐詞）；混合句就逐 CJK 字 + 逐拉丁詞，兩者放進同一個 token 序列算編輯
距離。「這個 sprint 的 blocker」→ ``['這','個','sprint','的','blocker']``。

DER 等 step 4 有 diarization 再接 pyannote.metrics——現在寫等於寫沒有呼叫者的程式碼。
"""

from __future__ import annotations

import argparse
import re
import sys
import unicodedata
from pathlib import Path

# CJK 統一表意文字 + 擴充 A + 相容表意文字 + 注音/假名（會議裡偶爾有日文專名）
_CJK = (
    r"぀-ヿ"      # 平假名 / 片假名
    r"㐀-䶿"      # 擴充 A
    r"一-鿿"      # 統一表意文字
    r"豈-﫿"      # 相容表意文字
)
_CJK_RE = re.compile(f"[{_CJK}]")
_LATIN_RE = re.compile(r"[a-z0-9]+(?:'[a-z]+)?", re.IGNORECASE)


def tokenize(text: str) -> list[str]:
    """CJK 逐字、拉丁逐詞，其餘（標點、空白）丟棄。

    正規化順序：NFKC（全形轉半形）→ 小寫 → 切 token。
    """
    text = unicodedata.normalize("NFKC", text).lower()
    tokens: list[str] = []
    i = 0
    while i < len(text):
        ch = text[i]
        if _CJK_RE.match(ch):
            tokens.append(ch)
            i += 1
            continue
        m = _LATIN_RE.match(text, i)
        if m:
            tokens.append(m.group())
            i = m.end()
            continue
        i += 1
    return tokens


def error_rate(reference: str, hypothesis: str) -> dict:
    """回傳 WER 與拆解後的錯誤數。中英夾雜下這其實是 token error rate。"""
    import jiwer  # 只有這個函式需要，import 放進來讓 tokenize 可以零相依使用

    ref = tokenize(reference)
    hyp = tokenize(hypothesis)
    if not ref:
        raise ValueError("reference 是空的，算不了 WER")
    out = jiwer.process_words(" ".join(ref), " ".join(hyp))
    return {
        "wer": out.wer,
        "substitutions": out.substitutions,
        "deletions": out.deletions,
        "insertions": out.insertions,
        "hits": out.hits,
        "ref_tokens": len(ref),
        "hyp_tokens": len(hyp),
    }


def percentile(values: list[float], pct: float) -> float:
    """線性內插百分位。樣本數少時 numpy 的 nearest-rank 會偏樂觀，這裡用內插。"""
    if not values:
        raise ValueError("沒有樣本")
    ordered = sorted(values)
    if len(ordered) == 1:
        return ordered[0]
    pos = (len(ordered) - 1) * pct / 100.0
    lo = int(pos)
    hi = min(lo + 1, len(ordered) - 1)
    return ordered[lo] + (ordered[hi] - ordered[lo]) * (pos - lo)


def _selfcheck() -> None:
    assert tokenize("這個 sprint 的 blocker") == ["這", "個", "sprint", "的", "blocker"]
    assert tokenize("Hello, World!") == ["hello", "world"]
    assert tokenize("ＡＢＣ１２３") == ["abc123"], tokenize("ＡＢＣ１２３")
    assert tokenize("") == []

    # 五個 token 錯一個 → 0.2
    r = error_rate("這個 sprint 的 blocker", "這個 sprint 的 blockers")
    assert abs(r["wer"] - 0.2) < 1e-9, r
    assert r["substitutions"] == 1 and r["ref_tokens"] == 5, r

    assert percentile([1, 2, 3, 4], 50) == 2.5
    assert percentile([10], 95) == 10
    # 1..100：pos = 99*0.95 = 94.05 → 95 + 0.05*(96-95) = 95.05
    assert abs(percentile(list(range(1, 101)), 95) - 95.05) < 1e-9
    print("selfcheck ok")


def main(argv: list[str] | None = None) -> int:
    ap = argparse.ArgumentParser(prog="eval.metrics")
    sub = ap.add_subparsers(dest="cmd", required=True)

    p = sub.add_parser("wer", help="比對兩個文字檔")
    p.add_argument("reference", type=Path)
    p.add_argument("hypothesis", type=Path)

    sub.add_parser("selfcheck")

    args = ap.parse_args(argv)
    if args.cmd == "selfcheck":
        _selfcheck()
        return 0

    result = error_rate(
        args.reference.read_text(encoding="utf-8"),
        args.hypothesis.read_text(encoding="utf-8"),
    )
    print(f"WER          {result['wer'] * 100:6.2f}%   (gate: < 12%)")
    print(f"  取代       {result['substitutions']}")
    print(f"  刪除       {result['deletions']}")
    print(f"  插入       {result['insertions']}")
    print(f"  ref/hyp    {result['ref_tokens']} / {result['hyp_tokens']} tokens")
    return 0 if result["wer"] < 0.12 else 1


if __name__ == "__main__":
    sys.exit(main())
