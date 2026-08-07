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
來源是 streaming 的重複輸出（同一句話講兩次），不是聽錯。

## endpointing：energy 比 fixed 差（否定結果）

假設是：`fixed` 每秒硬切會切在字中間，造成逐字稿破碎和邊界重複；改成 `energy`
（切在能量低點，也就是講話停頓）應該會好。**實測相反**，同樣前 120 秒、chunk 1.0：

| endpointing | partial P95 | final P95 | WER |
|---|---|---|---|
| **fixed** | **360 ms** | **367 ms** | **32.5%** ← 預設 |
| energy | 4293 ms | 4686 ms | 34.2% |

energy 模式會等到偵測到停頓才切，開會的人講話少有乾淨停頓，於是一塊拖到很長，
單次推論時間跟著爆掉，延遲 P95 4.3 秒。WER 也沒有變好。維持 `fixed`。

## 全長跑：25 分鐘，延遲不漂移

| | 前 120 秒 | 全長 1509.7 秒 |
|---|---|---|
| partial P95 | 362 ms | **381 ms** |
| final P95 | 363 ms | **382 ms** |
| WER | 32.5% | **29.4%** |

事件 1441 個 final、1509 個 partial，沒有 `gap`、沒有 `error`、沒有丟幀。

**這是最重要的一個數字**：25 分鐘後的 P95 跟 2 分鐘時一樣。舊版的死法是「越講越
落後」——延遲會隨時間單向增長。這裡沒有，代表推論確實沒有卡在收音路徑上。

## WER 還差得遠

29.4%，gate 是 12%（而且 gate 講的是繁中人工逐字稿，這裡是英文自動字幕，標準更寬）。
逐字稿看得懂但品質差，典型錯誤：

    ref:  Hey everyone, welcome to this week's security policies weekly meeting.
    hyp:  The. Hey everyone. Welcome this week. Security. Security policies weekly meet.

三種錯：邊界重複（`Security. Security`）、破碎成短句、無中生有的填充詞（`The.` `I.` `A.`）。

還沒試的槓桿，依預估效益排序：

1. **換大一點的模型**——現在是 `Qwen3-ASR-0.6B`，是這個家族最小的
2. `unfixed_token_num` / `unfixed_chunk_num`——控制尾巴保留多少可改寫空間，直接對應邊界重複
3. `context` 餵會議專有名詞（人名、`fastboot` 這種被聽成 `fast food` 的字）
4. `finalization_mode` / `enable_tail_refine`

## 尚未量測

- 繁中與中英夾雜的 WER（要先找有人工逐字稿的中文語料）
- DER（要等 pyannote 接上；GitLab 字幕的 `>>` 已經存成換人時間點當弱標註）
- pyannote 與 ASR 同時跑的 GPU 競爭
- 講者切換辨識延遲
