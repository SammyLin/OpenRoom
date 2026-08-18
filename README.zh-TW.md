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
| 後端 | 沒有。全部跑在 Mac app 內 |
| 前端 | SwiftUI（`native/OpenRoomApp`） |
| ASR | Qwen3-ASR，走 [mlx-audio-swift](https://github.com/Blaizzy/mlx-audio-swift)（本機） |
| Diarization | Sortformer 串流，同一個套件 |
| 語言 | 中英雙一級，含句中夾雜 |
| 音訊來源 | macOS 系統音訊擷取（錄 Teams / Google Meet） |
| 儲存 | `~/Library/Application Support/OpenRoom/runs/` 底下的檔案。原本決定用 SQLite；單機、一次一場、寫完只讀一次，資料庫換不到任何東西 |
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

1. ~~**eval harness**~~ 完成，後來跟 Python 後端一起退休
2. ~~音訊 → 落地存檔~~ 完成
3. ~~Qwen3-ASR MLX~~ 延遲 gate 已過，**WER 還沒**（29.4%，gate 12%）
4. ~~前端：逐字稿 + 健康面板~~ 完成
5. ~~即時分析層（面試／討論會議）~~ 完成，含匯出逐字稿
6. **拿它開一場真的會議** ← 現在在這裡。中文 37.6% WER、延遲過 gate，能讀
7. WER：`context` 餵專有名詞、`finalization_mode`（合併層的邊界重複已修掉 2pp）
8. ~~講者分離~~ 完成，DER 還沒量
9. ~~macOS 系統音訊擷取~~ 完成：ScreenCaptureKit 抓系統輸出（不靠瀏覽器分頁分享，
   Teams 桌面版也收得到）。第一次跑要在「系統設定 > 隱私權與安全性 > 螢幕與系統錄音」
   授權。
10. ~~拿掉 Python 後端~~ 完成。ASR、講者分離、分析層全部是 Swift 了，不用 `uv venv`、
    沒有 sidecar process、也不用申請 `HF_TOKEN`。下面那些數字是拿 Python 版量的，
    **還沒在 Swift 版重量過**。

原本排在最後的 LLM 層提前做了：逐字稿只是原料，**「一邊開會一邊給補充資料與追問建議」
才是這個工具存在的理由**，先把它跑起來才知道逐字稿要多準。

而磨 WER 排在真實使用**後面**，是因為 gate 是抄舊版 PRD 的，不是量出來需要的。
32% WER 的破碎英文逐字稿，分析層照樣吐得出可用的補充資料——所以主要指標是
insight 品質，WER 只當診斷。要標註 insight 品質就得先有東西可標，事件因此落地
（`~/Library/Application Support/OpenRoom/runs/<時間>-<meeting_id>/events.jsonl`）。

## 跑起來

打開 app 就好。沒有東西要安裝、沒有 venv、沒有 server 要開、也不用申請 token。

```bash
native/OpenRoomApp/build-app.sh   # → native/OpenRoomApp/OpenRoom.app
open native/OpenRoomApp/OpenRoom.app
```

模型第一次用會從 Hugging Face 下載並快取（約 1GB，放在
`~/.cache/huggingface/hub/mlx-audio/`，選單裡的「顯示模型檔案…」也走得到）。下載在**開始
收音之前**跑完，畫面上有下載量跟取消鈕：一顆轉了四分鐘的圈跟當掉長得一樣，而邊抓 1GB
邊緩衝音訊本來就會爆掉 `ready` 前的緩衝區。中途離開不會壞，下次續傳。抓下來的權重會對
Hugging Face 自己講的 sha256——被截斷的檔案或代理伺服器塞進來的錯誤頁，過得了套件那個
「有一個非零位元組的 safetensors」的檢查，然後在載入模型時炸成一個看不懂的錯誤。模型載完
之後 app 是**緩衝**音訊而不是丟棄——擋下來的是開場白，丟掉就沒了。

逐字稿是必要的，講者標籤不是。講者模型抓不到，會議照開並且在管線健康那一欄說出來——
沒有講者名字的逐字稿還是逐字稿。

每一場寫進 `~/Library/Application Support/OpenRoom/runs/<時間>-<meeting_id>/`：
`events.jsonl`（**所有** UI 收到的事件，含 `_wall_ms`）、`transcript.txt`（一句一句
append，當掉也留得住講過的話）、`meeting.json`（歷史清單讀的摘要）。
不用 SQLite——單機、一次一場、寫完只讀一次。過去的會議在 app 裡「過去的會議」看得到：
讀、匯出、在 Finder 顯示、刪到垃圾桶。預設永久保留——文字不佔空間，而會議紀錄自己過期
消失是最糟的預設值。

選「系統音訊」走 ScreenCaptureKit，直接抓系統輸出，Teams / Meet 桌面版跟瀏覽器分頁
一樣收得到。第一次跑要在「系統設定 > 隱私權與安全性 > 螢幕與系統錄音」授權；沒授權
app 會講出來並拒絕開始，而不是安靜地錄一片空白。

### 講者分離

Sortformer 是串流模型，講者標籤跟逐字稿一起到，不是回填的；跨 chunk 的講者身分由
streaming state 維持一致。它不是 gated repo，所以沒有 `HF_TOKEN` 這一步。

Python 版用的 pyannote 不是串流模型：身分要前後一致就得對「目前為止的整段音訊」重跑，
成本隨會議長度上升，還得用工作週期壓住，免得把 GPU 從 ASR 手上搶走。這些現在都不需要了。
`docs/measurements.md` 描述的是那個舊安排。

失敗一樣送 `speaker_error`，不會安靜地少標講者。

### 分析層

一邊聽一邊補資料，場合決定它看什麼：`interview` 挑答案的錯與該追問的問題，
`discussion` 補專有名詞與背景。LLM 預設走 `claude` CLI 的 print 模式（借 Claude Code 的
登入，這台沒有 `ANTHROPIC_API_KEY`），所以每輪要花錢，觸發有節流：累積 400 字
且距上輪 25 秒才跑，上一輪沒回來就跳過。

場合在 app 的設定畫面選，不是命令列參數。

分析永遠排在收音後面（`nice -n 15`，跑在自己的 Task，不會擋到收音或逐字稿）。
每一次跳過都送 `insight_error`，UI 看得到原因。

**LLM provider 可以換**，用 `OPENROOM_LLM_PROVIDER` 環境變數選（預設 `claude-cli`，
行為完全不變）：

| provider | 說明 | 相關環境變數 |
|---|---|---|
| `claude-cli` | 預設，`claude -p ... --output-format json` |（無）|
| `cli` | 換一支相容的 CLI（同樣的 `-p`/`--output-format json` 合約）| `OPENROOM_LLM_CLI`（工具名，例如 `codex`、`gemini`） |
| `anthropic-api` | 直接打 Anthropic Messages API | `ANTHROPIC_API_KEY` |
| `ollama` | 打本地 Ollama 伺服器 | `OLLAMA_HOST`（預設 `http://localhost:11434`）、`OPENROOM_OLLAMA_MODEL`（預設 `llama3.1`） |

`open` 不會把環境變數傳給 app，要用 `--env`：

```bash
open --env OPENROOM_LLM_PROVIDER=ollama --env OPENROOM_OLLAMA_MODEL=llama3.1 \
     native/OpenRoomApp/OpenRoom.app
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

### 下載回來的 build 打不開

Release 上掛的是 `.dmg`，而 macOS 會拒絕打開裡面的東西：

> 未打開「OpenRoom」——Apple 無法驗證「OpenRoom」是否含有可能危害 Mac 或洩漏隱私的惡意
> 軟體。

這是正確行為，不是 build 壞了。要用 Developer ID 簽章並公證需要付費的 Apple Developer
帳號，所以現在 release 是 adhoc 簽章（`codesign --sign -`）、沒有公證票。從網路下載的東
西一律被加上隔離屬性，而 macOS 不會執行「被隔離且未公證」的程式碼。

差別就是一張憑證。下載完直接開得起來的專案——例如這份 workflow 的範本
[openusage](https://github.com/robinebers/openusage)——它的 DMG 由
`Developer ID Application: … (QC3D3H67V9)` 簽章、一路串到 `Apple Root CA`，而且 staple
了公證票。我們的是 `Signature=adhoc`、`TeamIdentifier=not set`、
`does not have a ticket stapled to it`。`release.yml` 早就有一模一樣的簽章、公證、staple
步驟，只是 secret 是空的所以被 skip 掉。程式碼一行都不用改，缺的只是去註冊跟把 secret 填上。

**自己編是最誠實的繞法，也是唯一不需要你關掉防護的做法**：`build-app.sh` 產出的 bundle
從來沒有被隔離過，直接打得開。

真的要跑下載回來的版本：**系統設定 → 隱私權與安全性 → 安全性 →「仍要打開」**，或是

```bash
xattr -dr com.apple.quarantine /Applications/OpenRoom.app
```

跑之前先弄懂它做了什麼：隔離屬性正是 macOS 會去檢查下載程式碼的原因，拿掉它等於對這個
app 關掉那道檢查。對一顆你讀得懂原始碼、自己編出來的執行檔這樣做是合理的；把它當成處理
別人軟體的習慣則不是。

**自動更新仍然會動，而且這道關卡只需要過這一次。** Gatekeeper 擋的是**你**手動下載的那一
份；Sparkle 送來的更新不走那條路。`SUUpdateValidator` 的判斷是「EdDSA 簽章驗過**或**
codesign 與執行中的 app 相符」，兩者滿足其一即可，所以 adhoc build 靠 EdDSA 簽章就更新得
了。接著 `SUFileManager` 會在安裝前把解開的更新樹上的 `com.apple.quarantine` 移除。第一次
安裝時過一次 Gatekeeper，成本就只有這樣。

（這個結論是讀 Sparkle 原始碼得到的，不是在第二台機器上實際更新過。它是這條更新路徑值得
現在就接起來、而不是等憑證的理由，但跨機器的真實更新還沒做過。）

### 維護者的一次性設定

```bash
swift build -c release --package-path native/OpenRoomApp   # 先讓 SPM 把 Sparkle 的工具抓下來
KEYS=native/OpenRoomApp/.build/artifacts/sparkle/Sparkle/bin/generate_keys

$KEYS               # 產生金鑰對：私鑰進 login keychain，公鑰印出來
$KEYS -x private.key  # 匯出私鑰，貼進 secret 之後把這個檔案刪掉
```

1. 公鑰 → repository secret `SPARKLE_PUBLIC_ED_KEY`。`build-app.sh` 從這個環境變數讀，
   寫進 Info.plist 的 `SUPublicEDKey`；release.yml 每次 tag build 都會傳進去。兩把鑰匙
   必須同進同出，只給私鑰會被擋下來——那會簽出一份 appcast，而對應的 app 沒有東西可以
   驗證它，錯誤只會發生在使用者的機器上，CI 這邊一路綠燈。
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

上面第 1 到 4 步在這個 repo 已經做完了：金鑰對存在、兩半都是 repository secret、Pages 正
在服務 <https://sammylin.github.io/OpenRoom/appcast.xml>，feed 裡有當前版本的簽章項目。裡
面那把公鑰是 `WB8oDu+EGNgiVYDD5f+tcYo4OP7XWWJZSvvnyBQ8A/M=`，跟出貨 `Info.plist` 的
`SUPublicEDKey` 一致。只剩第 5 步的 Apple 簽章 secret 還沒有 —— 而那一步買到的是「第一次
安裝不用繞過 Gatekeeper」，不是「能不能更新」。

上面那份清單是 fork 出去的人要重做一遍的東西。

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

## eval harness（已退休）

沒有數字就無法說重寫有沒有變好，所以它排在任何產品程式碼之前。它是 Python 寫的：
從 YouTube 抓語料、照即時速度把音訊餵進 WebSocket、算 WER 與 P95 延遲。

它跟 Python 後端一起走了——它打的是 `ws://127.0.0.1:8000`，現在沒人在那裡聽。
**所以這份 README 跟 `docs/measurements.md` 裡的數字都是 Python 版量的，還沒在 Swift 版
重現過。** 講清楚，好過讓過期的數字冒充現況。

要在 Swift 版重建，做法是把 wav 餵進 `ASREngine` 再跟參考逐字稿比對；舊的語料工具
（`eval/corpus.py`、`eval/feed.py`、`eval/metrics.py`）在 git 歷史裡，值得撿再撿。

### 測試素材

- **GitLab Unfiltered**（<https://www.youtube.com/@GitLabUnfiltered/videos>）——真實多人
  會議、單一混音軌，正是講者分離要面對的東西。官方字幕可當 WER ground truth，但
  **英文 WER 不是產品指標**。
- **塞掐 Side Chat E417**（`6h6VsrclFTI`）——中文訪談、中英夾雜、**人工 zh-TW 字幕**
  （人打的逐字稿，比自動生成的可信）。繁中 WER 以這個為基準。
- **AMI Corpus**——完整講者標註，DER 的客觀基準。

**人工字幕不一定是逐字稿，可能是翻譯**（踩過：英文訪談配中文字幕，量出來的 80% WER
整個是假的）。
