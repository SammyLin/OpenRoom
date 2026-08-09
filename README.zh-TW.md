# OpenRoom

[English](README.md) · 繁體中文 · [简体中文](README.zh-CN.md) · [日本語](README.ja.md)

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

1. ~~**eval harness**~~ 完成
2. ~~音訊 → WS → 落地存檔~~ 完成（WS 端完成；macOS 系統音訊擷取待做）
3. ~~Qwen3-ASR MLX（獨立 process）~~ 延遲 gate 已過，**WER 還沒**（29.4%，gate 12%）
4. ~~前端：逐字稿 + 健康面板~~ 完成
5. ~~即時分析層（面試／討論會議）~~ 完成，含匯出逐字稿
6. **拿它開一場真的會議** ← 現在在這裡。中文 37.6% WER、延遲過 gate，能讀
7. WER：`context` 餵專有名詞、`finalization_mode`（合併層的邊界重複已修掉 2pp）
8. ~~pyannote 講者分離（獨立 process）~~ 完成，DER 還沒量
9. ~~macOS 系統音訊擷取~~ 完成：`native/openroom-capture`，ScreenCaptureKit 抓系統輸出
   （不靠瀏覽器分頁分享，Teams 桌面版也收得到），照 `docs/protocol.md` 直接當 WS
   client 接後端。第一次跑要在「系統設定 > 隱私權與安全性 > 螢幕與系統錄音」授權。

原本排在最後的 LLM 層提前做了：逐字稿只是原料，**「一邊開會一邊給補充資料與追問建議」
才是這個工具存在的理由**，先把它跑起來才知道逐字稿要多準。

而磨 WER 排在真實使用**後面**，是因為 gate 是抄舊版 PRD 的，不是量出來需要的。
32% WER 的破碎英文逐字稿，分析層照樣吐得出可用的補充資料——所以主要指標是
insight 品質，WER 只當診斷。要標註 insight 品質就得先有東西可標，事件因此落地
（`runs/<時間>-<meeting_id>/events.jsonl`）。

## 跑起來

```bash
uv venv --python 3.11 && source .venv/bin/activate
uv pip install -e '.[eval,dev,diarize]' 'mlx-qwen3-asr>=0.3.5'

export HF_TOKEN=hf_...                    # 講者分離的模型是 gated repo，見下面
python -m openroom.server --language en     # 不給 --language 就自動判斷（中英夾雜用這個）

cd app && npm install && npm run dev      # 前端 → http://localhost:5173
```

Server 會先預熱模型（第一次要編譯 Metal kernel，約 46 秒），**預熱完才送 `ready`**。
在那之前送音訊會收到 `error`，不會被靜靜吞掉。前端在 `ready` 之前**緩衝**而不是丟棄，
`ready` 之後照 seq 補送——擋下來的是開場白，丟掉就沒了。

每一場寫進 `runs/<時間>-<meeting_id>/`：`audio.raw`（原始 PCM）、`events.jsonl`
（**所有**送給前端的事件，含 `_wall_ms` 與 `infer_ms`）、`transcript.txt`。
不用 SQLite——單機、一次一場、寫完只讀一次。

前端選「系統音訊」會走瀏覽器的分享畫面對話框，**要勾「同時分享分頁音訊」**，
沒勾就沒有音訊軌，這時會直接報錯而不是安靜地錄一片空白。

### 講者分離

pyannote 跑在自己的 process，對「目前為止的整段音訊」重跑，所以講者身分前後一致。
模型是 **gated repo**：要先到
<https://huggingface.co/pyannote/speaker-diarization-community-1> 按同意，再設
`HF_TOKEN`。沒設會收到 `speaker_error`，不會安靜地少標講者。

```bash
python -m openroom.server --no-diarize            # 量 ASR 延遲時要關，兩邊搶同一顆 GPU
python -m openroom.server --diarize-idle-ratio 12 # 更保守：ASR 更穩，講者標籤更晚到
```

**講者標籤是回填的**，比逐字稿晚到數十秒；這是拿即時性換身分一致性，實測見
`docs/measurements.md`。

### 分析層

一邊聽一邊補資料，場合決定它看什麼：`interview` 挑答案的錯與該追問的問題，
`discussion` 補專有名詞與背景。LLM 預設走 `claude` CLI 的 print 模式（借 Claude Code 的
登入，這台沒有 `ANTHROPIC_API_KEY`），所以每輪要花錢，觸發有節流：累積 400 字
且距上輪 25 秒才跑，上一輪沒回來就跳過。

```bash
python -m openroom.server --scenario interview --llm-model claude-sonnet-5
python -m openroom.server --no-web-search   # 不讓它上網查證
```

分析永遠排在收音後面（`nice -n 15`，背景 task，ASR 落後超過 6 秒就整輪讓路）。
每一次跳過都送 `insight_error`，UI 看得到原因。

**LLM provider 可以換**，用 `OPENROOM_LLM_PROVIDER` 環境變數選（預設 `claude-cli`，
行為完全不變）：

| provider | 說明 | 相關環境變數 |
|---|---|---|
| `claude-cli` | 預設，`claude -p ... --output-format json` |（無）|
| `cli` | 換一支相容的 CLI（同樣的 `-p`/`--output-format json` 合約）| `OPENROOM_LLM_CLI`（工具名，例如 `codex`、`gemini`） |
| `anthropic-api` | 直接打 Anthropic Messages API | `ANTHROPIC_API_KEY` |
| `ollama` | 打本地 Ollama 伺服器 | `OLLAMA_HOST`（預設 `http://localhost:11434`）、`OPENROOM_OLLAMA_MODEL`（預設 `llama3.1`） |

```bash
OPENROOM_LLM_PROVIDER=anthropic-api ANTHROPIC_API_KEY=sk-ant-... python -m openroom.server
OPENROOM_LLM_PROVIDER=ollama OPENROOM_OLLAMA_MODEL=llama3.1 python -m openroom.server
```

四個 provider 都一樣：失敗一律送 `insight_error`，不會悄悄吐空結果。

## 自動更新

`native/OpenRoomApp/build-app.sh` 包出來的 .app 用 Sparkle 2 自己檢查更新，feed 放在
<https://sammylin.github.io/OpenRoom/appcast.xml>（`gh-pages` 分支，GitHub Pages 發的
靜態檔）。`SUEnableAutomaticChecks` **刻意不寫進 Info.plist**：寫了等於替使用者按下同
意，app 第一次啟動就自己連外。留白的結果是 Sparkle 第一次啟動時問過才開始檢查，之後
每 24 小時（`SUScheduledCheckInterval` 86400）一次；選單裡的「檢查更新…」隨時可以手
動按。

更新是「從網路抓程式下來執行」，所以只有一個判準：能不能驗簽章。下載的每一包都要過
EdDSA 簽章驗證，驗不過就拒絕安裝，沒有「先裝再說」的旗標。公鑰寫在 Info.plist 的
`SUPublicEDKey`，而 `build-app.sh` 拿不到公鑰時**整個 key 不寫**——不塞 placeholder，
因為一顆「看起來設定好了」的壞 build 正是這專案禁止的靜默降級。這種 build 裡的
updater 根本不會啟動：stderr 印一行 `no SUPublicEDKey in Info.plist — auto-update
disabled`，選單那一項灰掉並直說「無法更新——這個 build 沒有更新金鑰」，而不是按了沒
反應。

### 維護者的一次性設定

```bash
swift build -c release --package-path native/OpenRoomApp   # 先讓 SPM 把 Sparkle 的工具抓下來
KEYS=native/OpenRoomApp/.build/artifacts/sparkle/Sparkle/bin/generate_keys

$KEYS               # 產生金鑰對：私鑰進 login keychain，公鑰印出來
$KEYS -x private.key  # 匯出私鑰，貼進 secret 之後把這個檔案刪掉
```

1. 公鑰 → `SPARKLE_PUBLIC_ED_KEY`，`build-app.sh` 從這個環境變數讀，寫進 Info.plist。
   公鑰不是秘密。**但 release.yml 目前沒有把它傳進 build 那一步**，所以現在 tag 出來的
   build 仍然沒有 `SUPublicEDKey`——CI log 上有那三行 WARNING，選單是灰的。在接上去之
   前，只有本機 `export SPARKLE_PUBLIC_ED_KEY=... && native/OpenRoomApp/build-app.sh`
   包出來的 app 更新得了。
2. 私鑰 → repository secret `SPARKLE_PRIVATE_KEY`。release.yml 只用 stdin 餵給
   `generate_appcast`，不走 argv（runner 上每個 process 都讀得到 argv），也不落地。沒
   有這個 secret 就整份 appcast 不發：一份沒簽章或只剩一筆的 feed 比沒有 feed 更糟。
3. GitHub Pages 指到 `gh-pages` 分支（Settings > Pages > Deploy from a branch）。發
   appcast 是 workflow 的最後一步，順序是刻意的——feed 指向 GitHub Release 的下載網
   址，資產還不存在就不能先公告。
4. Apple 的簽章 secret：`APPLE_CERTIFICATE`（Developer ID Application 憑證的 .p12 轉
   base64）、`APPLE_CERTIFICATE_PASSWORD`、`APPLE_ID`、`APPLE_PASSWORD`（app-specific
   password）、`APPLE_TEAM_ID`。

### 沒有 Developer ID，自動更新等於沒有

這件事要講白。憑證與公證的 secret 沒設，release.yml 照樣出得了一顆 app，但那是 adhoc
簽章：**除了 build 它的那台機器，Gatekeeper 在每一台 Mac 上都會擋下來**。使用者得自己
`xattr -dr com.apple.quarantine /Applications/OpenRoom.app`，或自己從原始碼 build。連
裝都裝不起來的 app，自動更新沒有意義——Sparkle 抓下新版、驗完簽章、換掉 app，然後
Gatekeeper 一樣擋。所以在 Apple Developer Program 的憑證與公證到位之前，這條路是接好
的但走不通。CI 不會假裝沒事：沒有憑證、沒有公證，各出一則 warning，release notes 裡也
會有一段講明這顆是什麼狀態、要怎麼硬開。

### 發版

推 tag 就出貨，tag 的形狀決定一切：

```bash
git tag v0.2.0        && git push origin v0.2.0          # 正式版，所有安裝都會收到
git tag v0.2.0-beta.1 && git push origin v0.2.0-beta.1   # 帶 '-' 就是 prerelease，只進 beta channel
```

帶 `-` 的算 prerelease：GitHub Release 標成 prerelease，appcast 那一筆加
`--channel beta`；乾淨的 tag 不帶 channel，也就是每一顆安裝預設訂閱的那一條。這個判斷
在 workflow 開頭算一次，之後不再重算。目前 app 沒有設 `allowedChannels`，所以沒有任何
一顆 build 訂閱得到 beta——beta 版只出現在 GitHub Releases 頁面，要手動下載。

發版途中每一步都自己驗自己，出錯就當場非零退出：Info.plist 的版本要跟 tag 一致（Sparkle
比的就是這個字串）、這次的檔案必須出現在 appcast 裡而且帶 `sparkle:edSignature`、新的
feed 筆數不准比舊的少（少了就是有人的升級路徑被砍掉）。抓不到既有的 `gh-pages` 也是
硬錯誤——與其把整份歷史換成只有一筆的 feed，不如不發。

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

# 算 WER（CJK 逐字、拉丁逐詞，不用指定語言；只比前 N 秒要用 reference.jsonl）
python -m eval.metrics wer corpus/<slug>/reference.jsonl hypothesis.txt --until-sec 120
```

量 ASR 時用 `--no-analyst` 開 server，免得每跑一次就付一次 LLM 的錢。

**手動字幕不一定是逐字稿，也可能是翻譯**（踩過：英文訪談配中文字幕，WER 算出 80%
全是假的）。`fetch` 會比對影片語言並警告，`--langs` 可以指定字幕語言的偏好順序。

語料放 `corpus/`，不進版控。

### 測試素材

- **GitLab Unfiltered**（<https://www.youtube.com/@GitLabUnfiltered/videos>）——真實多人會議、
  單一混音音軌，正好打 diarization。有官方字幕可當 WER 的 ground truth，但**英文 WER
  不是產品指標**。
- **塞掐 Side Chat E417**（`6h6VsrclFTI`）——中文訪談、中英夾雜、**手動 zh-TW 字幕**
  （真人逐字稿，比自動字幕可信）。繁中 WER 的基準就用這支。
- **AMI Corpus**——有完整講者標註，DER 的客觀基準。等 diarization 那步才接。

`ffmpeg -re` 負責真實時間節奏；音訊走的路徑跟麥克風完全一樣，所以測得到延遲，
不是離線批次跑模型的假數字。
