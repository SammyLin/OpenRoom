# WS 協定（草案 v0）

音訊擷取、eval feeder、未來的麥克風路徑，全部走這一條。**feeder 和真實擷取共用同一份
協定，否則測到的延遲不算數。**

## 連線

```
ws://127.0.0.1:8000/ws/{meeting_id}
```

單機工具，不做 auth。

## Client → Server

### `start`（JSON，必須是第一個訊息）

```json
{
  "type": "start",
  "sample_rate": 16000,
  "channels": 1,
  "format": "s16le",
  "source": "system" | "mic" | "eval",
  "scenario": "interview" | "discussion",
  "engine": "qwen-mlx"
}
```

`scenario` 決定分析層怎麼看這場會議（面試判對錯、討論補背景），可省略，省略就用
server 啟動時的 `--scenario`。

Server 必須回 `ready` 或 `error`。**在收到 `ready` 之前送出的音訊，server 不得靜默丟棄**
——要嘛緩衝，要嘛回 `error`。（舊版 `gateway.py:141-143` 就是靜默丟棄，是「不會收音」的
成因之一。）

### 音訊（binary frame）

每一幀前面加 8 bytes header，其餘是 PCM：

```
| seq: uint32 BE | audio_ts_ms: uint32 BE | pcm: s16le mono 16kHz |
```

- `seq`：從 0 開始遞增。server 發現跳號要回 `gap` 事件，不得靜默接受。
- `audio_ts_ms`：這一幀第一個 sample 在會議中的毫秒位置。延遲量測靠它。
- payload 固定 100 ms = 1600 samples = 3200 bytes。

seq 存在的理由是「日後要補送斷線期間的音訊時不用改協定」。**現在不做 client 端
ring buffer**——單機 localhost 斷線機率趨近零，為不存在的問題付錢是舊版的死法。

### `stop`（JSON）

```json
{ "type": "stop" }
```

## Server → Client

所有事件都是 JSON。**每一個降級／丟棄／跳過都必須有對應事件**，這是硬規則。

| type | 意義 | 關鍵欄位 |
|---|---|---|
| `ready` | 可以開始送音訊 | `engine`, `sample_rate` |
| `partial` | 暫時逐字稿，會被 `final` 覆蓋 | `id`, `text`, `speaker`, `start_ms`, `end_ms`, `confidence` |
| `final` | 定稿逐字稿 | 同上 |
| `no_speech` | 這段音訊被能量閘門判為靜音而跳過 | `start_ms`, `end_ms`, `rms` |
| `gap` | server 偵測到 seq 跳號 | `expected_seq`, `got_seq`, `lost_ms` |
| `revise` | 模型回頭改寫已定稿的文字 | `from_char`, `text` |
| `speaker` | 講者標籤更新／合併 | `speaker`, `start_ms`, `end_ms` |
| `done` | 這場結束，帶權威全文 | `text`, `audio_ms` |
| `insight_pending` | 開始跑一輪分析（要幾秒，UI 得知道在跑） | `scenario`, `at_ms` |
| `insight` | 分析結果 | `headline`, `items[]`, `questions[]`, `at_ms`, `latency_ms` |
| `insight_error` | 分析失敗或**被跳過** | `code`, `message` |
| `error` | 任何失敗。**不得降級成假資料** | `code`, `message`, `fatal` |

分析層跳過一輪也算降級，所以照樣發事件：`llm_timeout`（CLI 沒回應）、`llm_failed`、
`llm_bad_output`（模型沒給可解析 JSON）、`asr_behind`（ASR 積壓太多，這輪讓路給逐字稿）。
唯一不發事件的情形是連線已經關掉——那時沒有對象可送，改印在 server log。

`partial` / `final` / `no_speech` 都必須帶 `start_ms` / `end_ms`，因為 eval 的延遲量測是：

```
latency = 事件抵達的 wall clock − 涵蓋 end_ms 的那一幀送出的 wall clock
```

沒有 `end_ms` 就量不出 P95。
