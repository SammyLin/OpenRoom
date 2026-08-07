# Huddle

單機的即時會議轉錄工具。Apple Silicon Mac，一次一場會議。

從舊版（`github.com/SammyLin/huddle` 的 Python/FastAPI/React 版本）重寫。舊版的失敗
不在語言或框架，而在**每一條失敗路徑都是靜音的**：session 未就緒的音訊靜默丟棄、
socket 沒開的送出靜默回 false、引擎名字打錯靜默掉回假資料產生器、能量低於固定門檻
靜默跳過。使用者看到的結果是「不會收音，也不會分析」，而且無法定位。

所以這版的第一守則不是模型品質，是：

> **不准靜默降級。** 任何降級、丟棄、跳過，都必須送出可見事件。

## 決策

| 項目 | 決定 |
|---|---|
| 形態 | 單機個人工具。一次一場會議，Apple Silicon only |
| 後端 | Python 3.11 |
| 前端 | Tailwind + shadcn（UX 重新設計） |
| ASR | Qwen3-ASR MLX（本機） |
| Diarization | pyannote.audio，**與 ASR 分成兩個 process** |
| 語言 | 中英雙一級，含句中夾雜 |
| 音訊來源 | macOS 系統音訊擷取（錄 Teams / Google Meet） |
| 儲存 | SQLite |
| 不做 | Postgres、Docker、Cloud Run、JWT、CORS、rate limit、simulator |

### 及格線（沿用舊版 PRD §4 NFR）

| 指標 | 目標 |
|---|---|
| partial 延遲 | < 800 ms P95 |
| final 延遲 | < 3 s P95 |
| 講者切換辨識延遲 | < 2 s |
| DER | < 15% |
| 繁中 WER | < 12% |

舊版 PRD 的「同時會議數 ≥ 10」已作廢——單機一顆 GPU 做不到，也不需要。

## 施工順序

1. **eval harness** ← 現在在這裡
2. 音訊擷取 → WS → 落地存檔（先證明收得到音）
3. Qwen3-ASR MLX（獨立 process）→ 過 WER gate
4. pyannote（獨立 process）→ 過 DER gate
5. 前端：逐字稿 + 講者
6. LLM 層：topic / sentiment / 建議 prompt / 修正
7. 匯出 / annotations

## eval harness

沒有數字就沒辦法說「重寫有沒有變好」，所以 harness 先於任何產品程式碼。

```bash
uv venv --python 3.11 && source .venv/bin/activate
uv pip install -e '.[eval]'

# 抓語料：YouTube 影片 → 16k mono wav + 官方字幕當 ground truth
python -m eval.corpus fetch 'https://www.youtube.com/watch?v=...'

# 列出已抓的語料
python -m eval.corpus list

# 依真實時間節奏把音訊灌進 WS（跟麥克風走同一條路），量 P95 延遲
python -m eval.feed corpus/<slug>/audio.wav --ws ws://127.0.0.1:8000/ws/test

# 算 WER
python -m eval.metrics wer corpus/<slug>/reference.txt hypothesis.txt --lang en
```

語料放 `corpus/`，不進版控。

### 測試素材

- **GitLab Unfiltered**（<https://www.youtube.com/@GitLabUnfiltered/videos>）——真實多人會議、
  單一混音音軌，正好打 diarization。有官方字幕可當 WER 的 ground truth，但**英文 WER
  不是產品指標**，繁中另外找語料。
- **AMI Corpus**——有完整講者標註，DER 的客觀基準。等 step 4 有 diarization 才接。

`ffmpeg -re` 負責真實時間節奏；音訊走的路徑跟麥克風完全一樣，所以測得到延遲，
不是離線批次跑模型的假數字。
