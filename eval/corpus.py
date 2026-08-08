"""語料抓取：YouTube 影片 → 16 kHz mono wav + 字幕 ground truth。

yt-dlp 和 ffmpeg 走 CLI，不進 Python 相依——它們是系統工具，包成 library 只會多一層
會過期的封裝。

產出結構（每支影片一個目錄）::

    corpus/<video_id>/
        audio.wav        16 kHz mono s16le，餵給 eval.feed
        reference.txt    純文字，算 WER 用
        reference.jsonl  {"start_ms","end_ms","text"} 逐句，日後對齊用
        meta.json        標題、時長、來源網址、字幕語言與是否為自動字幕

字幕是 ground truth，但**自動字幕本身就有錯**。英文自動字幕的字面正確率大致在 95%
以上，拿來看趨勢可以，拿來當「WER < 12%」的驗收標準不行——那條要用人工逐字稿。
"""

from __future__ import annotations

import argparse
import html
import json
import re
import shutil
import subprocess
import sys
from dataclasses import dataclass
from pathlib import Path

CORPUS_DIR = Path(__file__).resolve().parent.parent / "corpus"

SAMPLE_RATE = 16_000

# 偏好序：手動字幕優於自動字幕，因為自動字幕的錯會直接變成 ground truth 的錯。
SUB_LANGS = "en,en-US,en-GB,zh-TW,zh-Hant,zh"


class ToolMissing(RuntimeError):
    pass


def _require(tool: str) -> str:
    path = shutil.which(tool)
    if not path:
        raise ToolMissing(f"找不到 {tool}，請先 `brew install {tool}`")
    return path


def _run(cmd: list[str]) -> str:
    proc = subprocess.run(cmd, capture_output=True, text=True)
    if proc.returncode != 0:
        raise RuntimeError(
            f"指令失敗（exit {proc.returncode}）：{' '.join(cmd[:3])} …\n{proc.stderr.strip()[:2000]}"
        )
    return proc.stdout


# ---------------------------------------------------------------- VTT 解析

_TAG_RE = re.compile(r"<[^>]*>")
_CUE_RE = re.compile(
    r"(?P<start>\d{2}:\d{2}:\d{2}\.\d{3})\s+-->\s+(?P<end>\d{2}:\d{2}:\d{2}\.\d{3})"
)


@dataclass
class Cue:
    start_ms: int
    end_ms: int
    text: str
    # YouTube 自動字幕用 ">>" 標示換人講話。沒有講者身分，但**換人的時間點**是免費的
    # diarization 弱標註——step 4 算 DER 時可以省掉一大半人工標記。
    # ponytail: ">>" 出現在 cue 中間時，換人時間點只精確到該 cue 的起點（最多差幾秒）；
    # 要更準就得逐字時間軸對齊，等 DER 真的卡在這裡再說。
    turn_start: bool = False


def _clean_line(raw: str) -> str:
    """去掉 VTT 內嵌標籤、還原 HTML entity、壓縮空白。

    entity 一定要還原：``&gt;&gt;`` 不還原的話會被斷詞成 ``gt`` 這種假詞，直接汙染 WER。
    """
    return re.sub(r"\s+", " ", html.unescape(_TAG_RE.sub("", raw)).strip())


def _ts_to_ms(ts: str) -> int:
    hh, mm, rest = ts.split(":")
    ss, ms = rest.split(".")
    return ((int(hh) * 60 + int(mm)) * 60 + int(ss)) * 1000 + int(ms)


def parse_vtt(text: str) -> list[Cue]:
    """解析 VTT，並處理 YouTube 自動字幕的捲動重複。

    自動字幕是「捲動」的：第 N 個 cue 的內容，會原封不動再出現在第 N+1 個 cue 的
    開頭當作上下文。直接串接會讓每句話出現兩次，WER 立刻爛掉。做法是逐行去重——
    只保留沒有在前一個 cue 出現過的行。
    """
    cues: list[Cue] = []
    prev_lines: list[str] = []

    for block in re.split(r"\n\s*\n", text):
        m = _CUE_RE.search(block)
        if not m:
            continue
        # 時間軸那行後面還有 cue settings（align:start position:0%），整行丟掉
        body = block[m.end() :].split("\n", 1)[1] if "\n" in block[m.end() :] else ""
        cleaned = [_clean_line(raw) for raw in body.splitlines()]
        lines = []
        for line in cleaned:
            if line and line not in prev_lines and line not in lines:
                lines.append(line)
        # prev_lines 記的是這個 cue 的完整內容（含被去掉的），下一個 cue 才比得對
        prev_lines = [line for line in cleaned if line]
        if not lines:
            continue
        text = " ".join(lines)
        cues.append(
            Cue(
                start_ms=_ts_to_ms(m.group("start")),
                end_ms=_ts_to_ms(m.group("end")),
                text=text.replace(">>", " ").strip(),
                turn_start=">>" in text,
            )
        )
    return cues


# ---------------------------------------------------------------- 抓取

def _pick_subtitle(info: dict, langs: str = SUB_LANGS) -> tuple[str, str, bool] | None:
    """從 info.json 選一條字幕軌，回傳 (lang, url, is_auto)。手動優先。"""
    wanted = langs.split(",")
    for is_auto, key in ((False, "subtitles"), (True, "automatic_captions")):
        tracks = info.get(key) or {}
        for lang in wanted:
            if lang in tracks:
                for fmt in tracks[lang]:
                    if fmt.get("ext") == "vtt":
                        return lang, fmt["url"], is_auto
    return None


def fetch(url: str, corpus_dir: Path = CORPUS_DIR, force: bool = False,
          langs: str = SUB_LANGS) -> Path:
    ytdlp = _require("yt-dlp")
    ffmpeg = _require("ffmpeg")

    info = json.loads(_run([ytdlp, "--dump-single-json", "--no-warnings", url]))
    video_id = info["id"]
    out = corpus_dir / video_id
    if out.exists() and not force and (out / "audio.wav").exists():
        print(f"已存在，跳過：{out}（--force 可覆蓋）")
        return out
    out.mkdir(parents=True, exist_ok=True)

    print(f"影片：{info.get('title')}（{info.get('duration')} 秒）")

    # 音訊 → 16 kHz mono s16le。直接讓 yt-dlp 輸出到 stdout 再交給 ffmpeg，
    # 省掉一個中間檔。
    print("下載音訊並轉 16 kHz mono…")
    raw = out / "raw.audio"
    _run([ytdlp, "-f", "bestaudio", "--no-warnings", "-o", str(raw), url])
    _run(
        [ffmpeg, "-y", "-loglevel", "error", "-i", str(raw),
         "-ac", "1", "-ar", str(SAMPLE_RATE), "-c:a", "pcm_s16le",
         str(out / "audio.wav")]
    )
    raw.unlink(missing_ok=True)

    # 字幕
    picked = _pick_subtitle(info, langs)
    cues: list[Cue] = []
    lang = None
    is_auto = None
    if picked:
        lang, sub_url, is_auto = picked
        print(f"字幕：{lang}（{'自動' if is_auto else '手動'}）")
        # 手動字幕不一定是逐字稿，也可能是**翻譯**。踩過一次：一支英文訪談配
        # 手動 zh-TW 字幕，ASR 正確吐英文、reference 是中文，WER 算出 80% 全是假的。
        spoken = (info.get("language") or "")[:2]
        if spoken and not lang.startswith(spoken):
            print(f"⚠️  影片口說語言是 {spoken}，字幕卻是 {lang}——這條字幕很可能是翻譯，"
                  f"不能當 WER 的 ground truth")
        vtt = _run([_require("curl"), "-fsSL", sub_url])
        (out / "subs.vtt").write_text(vtt, encoding="utf-8")  # 留原始檔，改解析器不用重抓
        cues = parse_vtt(vtt)
        (out / "reference.txt").write_text(
            "\n".join(c.text for c in cues) + "\n", encoding="utf-8"
        )
        with (out / "reference.jsonl").open("w", encoding="utf-8") as fh:
            for c in cues:
                fh.write(json.dumps(c.__dict__, ensure_ascii=False) + "\n")
    else:
        print("警告：這支影片沒有可用字幕，只有音訊，算不了 WER")

    (out / "meta.json").write_text(
        json.dumps(
            {
                "id": video_id,
                "title": info.get("title"),
                "duration_sec": info.get("duration"),
                "url": info.get("webpage_url", url),
                "uploader": info.get("uploader"),
                "subtitle_lang": lang,
                "subtitle_is_auto": is_auto,
                "cue_count": len(cues),
                "turn_count": sum(c.turn_start for c in cues),
                "sample_rate": SAMPLE_RATE,
            },
            ensure_ascii=False,
            indent=2,
        ),
        encoding="utf-8",
    )
    print(f"完成：{out}")
    return out


def list_channel(channel_url: str, limit: int = 20) -> list[dict]:
    """列出頻道影片（不下載），挑素材用。"""
    ytdlp = _require("yt-dlp")
    raw = _run(
        [ytdlp, "--flat-playlist", "--dump-json", "--no-warnings",
         "--playlist-end", str(limit), channel_url]
    )
    return [json.loads(line) for line in raw.splitlines() if line.strip()]


def _selfcheck() -> None:
    """捲動字幕去重是這個檔唯一有邏輯的地方，測它。"""
    sample = """WEBVTT

00:00:01.000 --> 00:00:03.000 align:start position:0%
so the<00:00:01.5><c> first</c><00:00:02.0><c> thing</c>

00:00:03.000 --> 00:00:05.000 align:start position:0%
so the first thing
we need to<00:00:03.5><c> ship</c>

00:00:05.000 --> 00:00:07.000 align:start position:0%
we need to ship
&gt;&gt; is the API
"""
    cues = parse_vtt(sample)
    text = " ".join(c.text for c in cues)
    assert text == "so the first thing we need to ship is the API", text
    assert cues[0].start_ms == 1000 and cues[0].end_ms == 3000, cues[0]
    assert _ts_to_ms("01:02:03.456") == 3_723_456
    # entity 要還原，">>" 要變成換人標記而不是留在文字裡
    assert [c.turn_start for c in cues] == [False, False, True], cues
    assert "&" not in text and ">" not in text, text
    print("selfcheck ok")


def main(argv: list[str] | None = None) -> int:
    ap = argparse.ArgumentParser(prog="eval.corpus", description="抓評測語料")
    sub = ap.add_subparsers(dest="cmd", required=True)

    p_fetch = sub.add_parser("fetch", help="抓一支影片")
    p_fetch.add_argument("url")
    p_fetch.add_argument("--force", action="store_true")
    # 中文影片常常同時有英文翻譯字幕，不指定就會挑到翻譯的，WER 就白算了
    p_fetch.add_argument("--langs", default=SUB_LANGS,
                         help=f"字幕語言偏好順序，預設 {SUB_LANGS}")

    p_ch = sub.add_parser("channel", help="列出頻道影片")
    p_ch.add_argument("url")
    p_ch.add_argument("--limit", type=int, default=20)

    sub.add_parser("list", help="列出已抓的語料")
    sub.add_parser("selfcheck", help="跑內建檢查")

    args = ap.parse_args(argv)
    try:
        if args.cmd == "fetch":
            fetch(args.url, force=args.force, langs=args.langs)
        elif args.cmd == "channel":
            for i, v in enumerate(list_channel(args.url, args.limit), 1):
                dur = v.get("duration")
                mins = f"{dur // 60}:{dur % 60:02d}" if dur else "?"
                print(f"{i:3d}. [{mins:>6}] {v['id']}  {v.get('title', '')[:70]}")
        elif args.cmd == "list":
            if not CORPUS_DIR.exists():
                print("還沒有語料")
                return 0
            for d in sorted(CORPUS_DIR.iterdir()):
                meta_path = d / "meta.json"
                if not meta_path.exists():
                    continue
                meta = json.loads(meta_path.read_text(encoding="utf-8"))
                dur = meta.get("duration_sec") or 0
                print(
                    f"{d.name}  [{dur // 60}:{dur % 60:02d}]  "
                    f"sub={meta.get('subtitle_lang')}"
                    f"{'(auto)' if meta.get('subtitle_is_auto') else ''}  "
                    f"{(meta.get('title') or '')[:60]}"
                )
        elif args.cmd == "selfcheck":
            _selfcheck()
    except (ToolMissing, RuntimeError) as exc:
        print(f"錯誤：{exc}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
