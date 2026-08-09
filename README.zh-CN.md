# OpenRoom

[English](README.md) · [繁體中文](README.zh-TW.md) · 简体中文 · [日本語](README.ja.md)

全本地的会议实时转录。Apple Silicon Mac，一次只跑一场会议。

这是旧版本（`github.com/SammyLin/huddle` 那个 Python/FastAPI/React 项目）的重写。杀死旧版本
的不是语言也不是框架，而是**每一条失败路径都是静默的**：会话还没就绪就送进来的音频被一声不吭
地丢掉，往没打开的 socket 上发送只是默默返回 false，引擎名拼错了就默默退回到假数据生成器，能
量低于写死的阈值就默默跳过。用户看到的是"它收不到声音，也不做分析"，却没有任何办法判断到底是
哪一段坏了。

所以这一版的第一条规则不是模型质量：

> **不允许静默降级。** 任何降级、丢弃、跳过，都必须发出一个看得见的事件。

## 决策

| 项目 | 决策 |
|---|---|
| 形态 | 单机个人工具。一次一场会议，只支持 Apple Silicon |
| 后端 | Python 3.11 |
| 前端 | Tailwind + shadcn（UX 重新设计） |
| ASR | Qwen3-ASR MLX（端上运行） |
| 说话人分离 | pyannote.audio，**与 ASR 分属不同进程** |
| 语言 | 中文和英文都是一等公民，包括句内混说 |
| 音频来源 | macOS 系统音频采集（能录到 Teams / Google Meet） |
| 存储 | SQLite |
| 不做 | Postgres、Docker、Cloud Run、JWT、CORS、限流、模拟器 |

### 及格线（沿用旧 PRD §4 NFR）

| 指标 | 目标 |
|---|---|
| partial 延迟 | < 800 ms P95 |
| final 延迟 | < 3 s P95 |
| 说话人切换检测延迟 | < 2 s |
| DER | < 15% |
| 繁体中文 WER | < 12% |

旧 PRD 里"≥ 10 场并发会议"作废——一台机器一块 GPU 做不到，也不需要做到。

## 开发顺序

1. ~~**评测框架**~~ 已完成
2. ~~音频 → WS → 落盘~~ 已完成（WS 这一侧完成；macOS 系统音频采集仍待做）
3. ~~Qwen3-ASR MLX（独立进程）~~ 延迟这关过了，**WER 没过**（29.4%，及格线 12%）
4. ~~前端：转录稿 + 健康面板~~ 已完成
5. ~~实时分析层（面试 / 讨论）~~ 已完成，含转录稿导出
6. **拿真实会议跑一遍** ← 我们在这里。中文 WER 37.6%，延迟过线，读得下去
7. WER：用 `context` 喂专有名词、`finalization_mode`（合并层的边界重复已经修掉，值 2 个百分点）
8. ~~pyannote 说话人分离（独立进程）~~ 已完成，DER 尚未测量
9. ~~macOS 系统音频采集~~ 已完成：`native/openroom-capture`，用 ScreenCaptureKit 抓系统输出
   （不依赖浏览器标签页共享，所以 Teams 桌面客户端也录得到），并直接按 `docs/protocol.md`
   以 WS 客户端身份连上后端。首次运行需要在系统设置 > 隐私与安全性 > 屏幕与系统音频录制里
   授权。

原本排在最后的 LLM 层被提前了：转录稿只是原料，**"会议还在开的时候就给我补充材料和追问"才是这
个工具存在的理由**，而且只有真跑起来，才知道转录到底需要准到什么程度。

而死磕 WER 排在真实使用**之后**，是因为那条及格线是从旧 PRD 抄来的，不是测出来的需求。32% WER
的破碎英文转录稿，分析层照样能产出可用的补充材料——所以首要指标是洞察质量，WER 只是诊断用的。
要给洞察质量打标签就得先有东西可标，这也是事件要落盘的原因
（`runs/<timestamp>-<meeting_id>/events.jsonl`）。

## 运行

```bash
uv venv --python 3.11 && source .venv/bin/activate
uv pip install -e '.[eval,dev,diarize]' 'mlx-qwen3-asr>=0.3.5'

export HF_TOKEN=hf_...                    # 说话人分离模型是受限仓库，见下文
python -m openroom.server --language en     # 省略 --language 就是自动检测（中英混说用这个）

cd app && npm install && npm run dev      # 前端 → http://localhost:5173
```

服务端会先把模型预热（第一次运行要编译 Metal kernel，大约 46 秒），**预热完成后才发 `ready`**。
在那之前送进来的音频会收到一个 `error`，而不是被悄悄吞掉。前端在 `ready` 之前是**缓冲**而不是
丢弃，之后按 seq 顺序重发——被扣住的是开场白，一旦丢了就找不回来。

每一场会话都会写进 `runs/<timestamp>-<meeting_id>/`：`audio.raw`（裸 PCM）、`events.jsonl`
（发给前端的**每一个**事件，带 `_wall_ms` 和 `infer_ms`）、`transcript.txt`。不用 SQLite——
一台机器、一次一场会议、写一次读一次。

在前端选"系统音频"会走浏览器的屏幕共享对话框，你**必须勾上"共享标签页音频"**；不勾就没有音频
轨，这种情况下它会直接报错，而不是安静地录一段无声。

### 说话人分离

pyannote 跑在自己的进程里，并且每次都对"到目前为止的整段音频"重跑一遍，所以说话人身份能随时间
保持一致。这个模型在**受限仓库**里：先到
<https://huggingface.co/pyannote/speaker-diarization-community-1> 接受条款，再设置
`HF_TOKEN`。没有它你会拿到 `speaker_error`，而不是悄无声息地丢掉说话人标签。

```bash
python -m openroom.server --no-diarize            # 测 ASR 延迟时关掉，两边会抢同一块 GPU
python -m openroom.server --diarize-idle-ratio 12 # 更保守：ASR 更稳，说话人标签更晚
```

**说话人标签是回填的**，会比转录稿晚几十秒到；这是拿实时性换身份一致性。测量结果在
`docs/measurements.md`。

### 分析层

它一边听一边补材料；找什么由场景决定。`interview` 挑出答错的地方和值得追问的问题；`discussion`
补齐专有名词和背景。LLM 默认走 `claude` CLI 的 print 模式（借用 Claude Code 的登录态，因为这台
机器没有 `ANTHROPIC_API_KEY`），所以每一轮都要花钱，触发条件因此被限流：累积满 400 个字符、
且距上一轮过了 25 秒才会跑，上一轮还没回来就跳过。

```bash
python -m openroom.server --scenario interview --llm-model claude-sonnet-5
python -m openroom.server --no-web-search   # 不让它上网查证
```

分析永远排在音频采集后面（`nice -n 15`、后台任务，而且只要 ASR 落后超过 6 秒，整轮就让路）。
每一次跳过都会发 `insight_error`，所以原因在 UI 上看得见。

**LLM provider 可以换**，用 `OPENROOM_LLM_PROVIDER` 环境变量选（默认 `claude-cli`，行为不变）：

| provider | 说明 | 相关环境变量 |
|---|---|---|
| `claude-cli` | 默认，`claude -p ... --output-format json` |（无）|
| `cli` | 换成兼容的 CLI（同样的 `-p`/`--output-format json` 约定）| `OPENROOM_LLM_CLI`（工具名，例如 `codex`、`gemini`） |
| `anthropic-api` | 直接调用 Anthropic Messages API | `ANTHROPIC_API_KEY` |
| `ollama` | 调用本地的 Ollama 服务 | `OLLAMA_HOST`（默认 `http://localhost:11434`）、`OPENROOM_OLLAMA_MODEL`（默认 `llama3.1`） |

```bash
OPENROOM_LLM_PROVIDER=anthropic-api ANTHROPIC_API_KEY=sk-ant-... python -m openroom.server
OPENROOM_LLM_PROVIDER=ollama OPENROOM_OLLAMA_MODEL=llama3.1 python -m openroom.server
```

四个 provider 的行为一致：任何失败都发 `insight_error`，没有一个会悄悄返回空结果。

## eval harness

没有数字就没法说重写到底改好了什么，所以评测框架比任何产品代码都先写。

```bash
uv venv --python 3.11 && source .venv/bin/activate
uv pip install -e '.[eval]'

# 抓语料：YouTube 视频 → 16k 单声道 wav + 官方字幕当 ground truth
python -m eval.corpus fetch 'https://www.youtube.com/watch?v=...'

# 列出已经抓下来的语料
python -m eval.corpus list

# 按实时速度把音频灌进 WS（和麦克风走同一条路径），测 P95 延迟
python -m eval.feed corpus/<slug>/audio.wav --ws ws://127.0.0.1:8000/ws/test

# 算 WER（CJK 按字、拉丁按词，不需要语言标志；只比前 N 秒需要 reference.jsonl）
python -m eval.metrics wer corpus/<slug>/reference.jsonl hypothesis.txt --until-sec 120
```

测 ASR 的时候用 `--no-analyst` 启动服务端，免得每跑一次就给 LLM 付一次钱。

**人工字幕不一定就是转录稿——它可能是翻译**（踩过：英文访谈配中文字幕，跑出来的 80% WER 全是
假的）。`fetch` 会拿视频语言做比对并给出警告；`--langs` 用来设定字幕语言的优先顺序。

语料放在 `corpus/`，不纳入版本控制。

### 测试素材

- **GitLab Unfiltered**（<https://www.youtube.com/@GitLabUnfiltered/videos>）——真实的多人会议，
  混在单条轨道上，正是说话人分离要面对的情况。官方字幕可以当 WER 的 ground truth，但
  **英文 WER 不是产品指标**。
- **塞掐 Side Chat E417**（`6h6VsrclFTI`）——中文访谈，中英混说，**人工 zh-TW 字幕**（人写的
  转录稿，比自动生成的可信）。这是繁体中文 WER 的基准。
- **AMI Corpus**——完整的说话人标注，DER 的客观基准。等说话人分离做到那一步再接上。

实时节奏由 `ffmpeg -re` 提供；音频走的路径和麦克风完全一样，所以测出来的延迟是真的，不是把模型
离线批处理跑出来的那种假数字。
