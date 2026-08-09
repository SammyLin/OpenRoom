# huddle-diarize

解決 `huddle/diarize_worker.py` 幾乎每次都吐 `speaker_error` / `hf_token_missing` 的問題：
pyannote/speaker-diarization-community-1 是 gated repo，要登入 HuggingFace 換 `HF_TOKEN`，
而測試環境幾乎從沒設過。

[FluidAudio](https://github.com/FluidInference/FluidAudio) 把同一套 pipeline（pyannote
segmentation + WeSpeaker embedding）轉成 CoreML，放在**公開、不用登入**的
`FluidInference/speaker-diarization-coreml`。這支 CLI 就是拿 FluidAudio 換掉
pyannote/HF_TOKEN 那條路——先驗證它真的能跑、真的不用 token，之後才輪到 Python 那邊接線。

**現況：只到這裡。`huddle/server.py` / `huddle/diarize_worker.py` 還沒改，這支還沒被接進去。**

## Build

```bash
cd native/huddle-diarize
swift build -c release
```

跟 `native/huddle-capture` 一樣 Apple Silicon / macOS 14+（FluidAudio 的下限，比
huddle-capture 的 13+ 高）。第一次 `swift build` 會從 GitHub 抓 FluidAudio 原始碼，
需要網路。

## 跑

```bash
.build/release/huddle-diarize <audio-file>
```

- 有容器的檔案（`.wav`、`.aiff`、`.caf`…）：直接讀，`AVAudioFile` 自己處理格式/重採樣，
  不限定一定要 16kHz mono——它會 resample。
- `.pcm` / `.raw`：當作沒有 header 的 16kHz mono s16le 原始 PCM。**這剛好是
  `huddle/server.py` 自己落地的格式**——`WorkerConfig.record_dir / "audio.raw"`
  （見 `huddle/server.py:58`）不用轉檔就能直接餵進來。

第一次跑會從 HuggingFace 下載模型（segmentation + embedding，共 ~13MB）到
`~/Library/Application Support/FluidAudio/Models/speaker-diarization/`，之後跑都是本地
cache，不再連網。**全程不用 `HF_TOKEN`**——這是這支工具存在的理由，已經實測確認。

`--selfcheck` 跑一個不用模型、不用網路的純邏輯自我檢查（raw PCM 的 s16le 小端解碼）。

## 輸出格式

進度/錯誤訊息印到 stderr，最後一行印到 stdout，一個 JSON array：

```json
[
  {"speaker": "1", "start_ms": 0, "end_ms": 6834},
  {"speaker": "2", "start_ms": 7256, "end_ms": 9939}
]
```

欄位對齊 `docs/protocol.md` 的 `speaker_turns` 事件裡 `turns[]` 的形狀
（`huddle/diarize_worker.py:_turns()` 產出的同一個 shape、`app/src/lib/protocol.ts`
的 `SpeakerTurn` 型別）：`speaker`（string，不保證是 `SPEAKER_00` 這種格式，FluidAudio
給的是 `"1"`、`"2"`…，反正前端本來就會用 `speakerNames()` 依出現順序重新命名，不管原始
label 長什麼樣）、`start_ms`、`end_ms`（都是整數毫秒）。這支只印 `turns[]` 本體，不印
`speakers` / `covers_ms` / `infer_ms`——那三個是 Python 端組 `speaker_turns` 事件時，
用這份 JSON 自己算（`len(turns)` 個 unique speaker、音檔總長、跑了多久）。

## 測過的行為（實測，不是猜的）

用 `say -v Tingting` / `say -v Meijia` 兩個中文語音各錄一段、`afconvert`/`ffmpeg` 轉成
16kHz mono s16le WAV、頭尾接起來（含靜音間隔）做出一個 ~22 秒兩講者的測試檔：

```
$ .build/release/huddle-diarize test_meeting.wav
載入 350573 samples（21.9s）…
載入模型中…（第一次跑會從 HuggingFace 下載 FluidInference/speaker-diarization-coreml，公開 repo，不用 HF_TOKEN）
[{"speaker":"1","start_ms":0,"end_ms":6834},{"speaker":"1","start_ms":7256,"end_ms":9939},
 {"speaker":"1","start_ms":10000,"end_ms":14725},{"speaker":"1","start_ms":15333,"end_ms":19939},
 {"speaker":"2","start_ms":20304,"end_ms":21873}]
```

- 真的建置成功（`swift build -c release`，Swift 6.2 / macOS 26.2 / Apple Silicon）。
- 真的從公開 repo 下載模型、沒設 `HF_TOKEN`、沒有任何 401／gated repo 錯誤。
- 真的吃 WAV、真的吃 headerless raw PCM（用 `server.py` 落地的同一種格式測過），
  兩條路都印出結構正確的 JSON。
- ⚠️ **講者分群品質在這份合成測試音檔上不準**：實際排列是「講者A（0–6.7s）→
  講者B（7.4–14.7s）→ 講者A（15.4–21.9s）」，但輸出把前三段全標成同一個 speaker，
  只在最後一段才切出第二個講者。沒去查是預設 `clusteringThreshold`/`chunkDuration`
  沒調、還是 macOS TTS 兩個語音的音色對 embedding model 來說本來就不夠有區分度——
  這题需要拿真人語音重新量一次才知道，不是這支 CLI 有 bug（JSON 結構、講者數量、
  時間戳都是對的，只是分群結果不理想）。**這是把它接進 server.py 之前一定要先量的
  東西，不能假設 FluidAudio 開箱就跟 pyannote 一樣準。**

## Python 端要怎麼接（下一步，這次沒做）

`huddle/diarize_worker.py` 現在整段邏輯是「pyannote pipeline 常駐在 subprocess 裡，
inference 直接呼叫 Python API」。要換成這支 CLI，最小改動大概是：

1. `_load()` 那段（`pyannote.audio` import + `HF_TOKEN` 檢查 + `Pipeline.from_pretrained`）
   整段刪掉，不用再管 gated repo。
2. `run()` 迴圈裡呼叫 pipeline 的地方，改成 `subprocess.run(["huddle-diarize", raw_pcm_path], capture_output=True)`
   ——但這支 CLI 目前吃的是**檔案路徑**，不是 stdin 流；`run()` 現有的邏輯是把 accumulate
   起來的 `audio: np.ndarray` 傳給 pipeline，改用 CLI 就要先把這段 `audio` 寫成一個暫存
   `.raw` 檔（或者更省事：直接指到 `record_dir/audio.raw`，只是那份是「目前為止」還是
   「整場」要對齊清楚）再傳路徑進去。
3. `subprocess.run` 回來的 stdout 直接 `json.loads`，就是 `_turns()` 現在回傳的
   `list[dict]`——`speaker`/`start_ms`/`end_ms` 欄位名完全對得上，`_turns()` 那段
   合併相鄰同講者小段、丟 <200ms 雜訊段的後處理邏輯應該保留，套在這支 CLI 的輸出上。
4. `speaker_ready` 事件的時機要重新想：現在是「pipeline 載入成功」就發，換成 CLI 後
   可能要在第一次 `swift build` 產出的執行檔存在時就發，或乾脆拿掉，因為 FluidAudio
   模型是 CLI 自己內部下載，Python 端看不到下載進度。

沒做的原因：上面那步是「拿掉 gated 依賴」的工程決策，需要人看過分群品質的實測結果
（見上一節的警告）再決定要不要真的換，不是這次任務的範圍。
