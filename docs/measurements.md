# 量測紀錄

所有數字都是 `eval/feed.py` 按真實時間（`ffmpeg -re`）灌音訊、走 `docs/protocol.md`
的完整路徑量到的。離線批次跑模型的數字不列在這裡，因為那量不到「推論會不會拖累收音」。

機器：Apple Silicon（arm64）、macOS 26.2、Python 3.11、mlx-qwen3-asr 0.3.5、
模型 `Qwen/Qwen3-ASR-0.6B`。

素材：GitLab Unfiltered《Security Risk Management: Security Policies - Weekly Meeting
- 2026-06-24》（`I5Of6ps2Ec4`，25 分 10 秒，646 個字幕 cue、85 次講者換人）。
Ground truth 是 YouTube **自動**字幕，本身就有錯，所以 WER 只能看趨勢，不能當驗收。

---

## 冷啟動：第一次推論 46 秒

第一次 `feed_audio` 要編譯 Metal kernel，實測 46.3 秒，之後穩態每塊 0.2–0.5 秒。

這件事若發生在會議開始，就是開場前 46 秒全部丟失——正是舊版「不會收音」的體感。
所以 worker 先用靜音預熱，**預熱完才送 `ready`**，client 在那之前不會送音訊。

## chunk_size_sec 掃描（前 120 秒，2026-08-08）

| chunk | partial P95 | final P95 | WER | 判定 |
|---|---|---|---|---|
| 2.0 s | 2407 ms | 2259 ms | 26.3% | partial 不過 |
| **1.0 s** | **362 ms** | **363 ms** | 32.5% | **兩個都過** ← 目前預設 |
| 0.5 s | 5130 ms | 4595 ms | 59.7% | 兩個都不過，且崩潰 |

三件事：

1. **延遲 = 單塊推論時間**，不是佇列堆積。事件抵達時間減音訊位置（lag）幾乎等於
   `infer_ms`，代表音訊進來從來沒有等過推論——獨立 process 這個設計有效。
2. **2.0 秒不是越大越好。** 一塊要吐的字越多，autoregressive 解碼越久，P95 就被
   那些話很密的塊拉到 2.4 秒。
3. **0.5 秒會崩。** 每秒兩次推論的固定成本讓 RTF 越過 1，佇列開始堆積，延遲滾到
   5 秒、WER 掉到 60%。**這就是舊版的死亡螺旋，現在有數字了。**

WER 在 26–32% 之間，離 12% 的 gate 很遠。錯誤分布裡**插入**最多（28 / 40 / 79），
來源是 streaming 的重複輸出（同一句話講兩次），不是聽錯。下一步的槓桿在
`finalization_mode` / `unfixed_token_num` / `detect_repetition`，不在換模型。

## 尚未量測

- 繁中與中英夾雜的 WER（要先找有人工逐字稿的中文語料）
- DER（要等 pyannote 接上；GitLab 字幕的 `>>` 已經存成換人時間點當弱標註）
- pyannote 與 ASR 同時跑的 GPU 競爭
- 講者切換辨識延遲
