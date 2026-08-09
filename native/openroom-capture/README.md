# openroom-capture

解決施工順序 #9：macOS 系統音訊擷取。瀏覽器 `getDisplayMedia` 只能分享「分頁／視窗」
音訊，Teams 桌面版沒有分頁可分享，所以抓不到。ScreenCaptureKit 抓的是系統輸出的
loopback audio，不管來源是網頁還是桌面 app 都收得到。

不是一個 app，是一支照 `docs/protocol.md` 講話的 WS client——跟瀏覽器前端、eval
feeder 共用同一份協定，所以不用改後端一行程式碼。

## Build

```bash
cd native/openroom-capture
swift build -c release
```

Apple Silicon only（跟專案其他部分一樣），需要 macOS 13+（ScreenCaptureKit 音訊
設定 API：`SCStreamConfiguration.sampleRate` / `.channelCount`）。

## 第一次跑之前

macOS 系統設定 → 隱私權與安全性 → 螢幕與系統錄音，把終端機（或這支執行檔）加進去。
沒授權會直接噴錯，不會跳系統提示視窗。

## 跑

```bash
# 後端要先跑：python -m openroom.server
.build/release/openroom-capture --meeting-id my-meeting --scenario discussion
# Ctrl-C 停止
```

```
usage: openroom-capture [--meeting-id ID] [--host H] [--port P]
       [--scenario discussion|interview] [--duration SEC] [--verbose]
```

沒給 `--duration` 就一直錄到 Ctrl-C。`--verbose` 會印 partial（不然只印 final／
insight／講者／錯誤事件）。

## 測過的行為

- 跟後端的 `ready` / `start` / 100ms 固定幀 / `stop` / `done` 握手完全照協定走，
  沒有 gap 事件（`Sources/openroom-capture/WSClient.swift`）。
- 真的放系統音訊（`say` TTS）進去，後端 ASR 收到、轉出逐字稿——不是只收到靜音幀。
- 沒放聲音時（系統靜音）落地 PCM 全部是 0，後端正確判定 `no_speech`，沒有假訊號。

## 已知限制

- 音訊格式假設 ScreenCaptureKit 用你在 `SCStreamConfiguration` 指定的
  `sampleRate`/`channelCount` 直接輸出（Float32），不做手動重採樣。目前測試機上
  正確；理論上如果某台 Mac 的 driver 不遵守這個設定，會整段錄到雜訊而非崩潰，
  ponytail: 沒加格式校驗，有人反應轉錄整段亂碼再回來查這裡。
- 沒有 reconnect／ring buffer，跟 server 端同一個哲學：單機 localhost，斷線機率
  趨近零，先不為不存在的問題付錢。
