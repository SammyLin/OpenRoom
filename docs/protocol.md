# 事件協定（v1，行程內）

以前這是一份 WebSocket 協定：`openroom-capture` 送音訊到 `ws://127.0.0.1:8000/ws/{meeting_id}`，
Python server 回事件。那個 server 已經沒有了——ASR、講者分離、分析層都在 `OpenRoomApp`
裡面跑，音訊是 function call 送進去的，不是 socket。

留下來的是**事件詞彙**：`ASREngine` / `Diarizer` / `Analyst` 發的字典、`MeetingSession.handle`
認得的 type、`events.jsonl` 裡每一行，都是這一份。傳輸方式換掉了，協定沒有。

## 硬規則

**每一個降級／丟棄／跳過都必須有對應事件。** 靜靜跳過的東西，散會後沒有人查得出來。

## 事件

所有事件都是 JSON 物件，一定有 `type`。`EventLog` 另外補一個 `_wall_ms`（相對開場的毫秒）。

| type | 意義 | 關鍵欄位 |
|---|---|---|
| `ready` | ASR 模型載好，可以開始轉錄 | `engine`, `model`, `sample_rate`, `warmup_sec` |
| `partial` | 暫時逐字稿，會被 `final` 取代 | `text`, `speaker`, `start_ms`, `end_ms` |
| `final` | 定稿逐字稿（增量，不是全文） | 同上 |
| `no_speech` | 這段音訊被判為靜音而跳過 | `start_ms`, `end_ms` |
| `gap` | 音訊沒被完整處理 | `lost_ms`, `reason`(`asr_backpressure`) |
| `speaker_ready` | 講者分離模型載好了 | `model`, `skipped_ms`（載入期間流掉、沒有講者標籤的音訊） |
| `speaker_turns` | **整份**講者時間軸，取代前一份 | `turns[]`, `speakers`, `covers_ms`, `infer_ms` |
| `speaker_error` | 講者分離失敗或跳過 | `code`, `message`（`model_load_failed` / `model_unavailable` / `diarize_failed` / `diarize_backpressure`，後者帶 `lost_ms`） |
| `speaker_done` | 講者分離收工，尾巴那段也跑完了 | — |
| `insight_pending` | 開始跑一輪分析（要幾秒，UI 得知道在跑） | `scenario`, `at_ms` |
| `insight` | 分析結果 | `headline`, `items[]`, `questions[]`, `at_ms`, `latency_ms` |
| `insight_none` | 這一輪沒有值得說的事 | `at_ms` |
| `insight_error` | 分析失敗或**被跳過** | `code`, `message` |
| `error` | 任何失敗。**不得降級成假資料** | `code`, `message`, `fatal` |
| `done` | 這場結束，帶權威全文 | `text`, `audio_ms` |

`speaker_turns` 每次送的是整份時間軸，不是增量：跨 chunk 的切點會被修正，client 整份換掉。

⚠️ **講者 id 不能直接當顯示名稱**：`SPEAKER_02` 這種編號跨輪不保證穩定，UI 照「第一次出現
的時間順序」重新命名（`speakerNames`），那個順序才不會跳動。

分析層跳過一輪也算降級，所以照樣發事件：`llm_timeout`（CLI 沒回應）、`llm_failed`、
`llm_bad_output`（模型沒給可解析 JSON）、`asr_behind`（ASR 積壓太多，這輪讓路給逐字稿）。

`partial` / `final` / `no_speech` 都必須帶 `start_ms` / `end_ms`——沒有 `end_ms` 就量不出延遲。

## 收工順序

`done` 跟 `speaker_done` 兩個都到齊，`EventLog` 才關檔。ASR 停止之後還會非同步吐出最後
幾句 `final` 跟 `done`，提早關檔等於把逐字稿尾巴丟掉，`meeting.json` 的長度、句數、標題
也會少算。
