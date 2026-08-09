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
| 存储 | `runs/` 下面的文件。原本决定用 SQLite；单机、一次一场、写完只读一次，数据库换不到任何东西 |
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

## 发布与自动更新

`OpenRoom.app` 由 `native/OpenRoomApp/build-app.sh` 组出来（一支 shell 脚本，不是 Xcode
工程），里面带 Sparkle 2。

### 更新怎么来

程序自己去查更新，feed 是 gh-pages 分支上的一个静态文件：
<https://sammylin.github.io/OpenRoom/appcast.xml>。Info.plist 里**刻意不写**
`SUEnableAutomaticChecks`——写了 Sparkle 就会跳过第一次启动的询问，等于这个程序没问过就
自己连外。所以首次启动会问一次要不要检查更新，你答应了才开始；之后每
`SUScheduledCheckInterval` 86400 秒（24 小时）查一次，菜单里的"检查更新…"随时能手动查。

下载回来的东西要过 EdDSA 签名验证：Sparkle 拿 Info.plist 里的 `SUPublicEDKey` 去核对
appcast 那一条的 `sparkle:edSignature`，对不上就拒绝安装。`build-app.sh` 只在
`SPARKLE_PUBLIC_ED_KEY` 有值时才写 `SUPublicEDKey`，没有就整个不写、并在 stderr 上喊；
程序发现自己没有公钥就根本不启动 updater，菜单里那一项灰掉、写着无法更新。一个按了没反应
的"检查更新"就是静默降级。

### 下载回来的 build 打不开

Release 上挂的是 `.dmg`，而 macOS 会拒绝打开里面的东西：

> 未打开“OpenRoom”——Apple 无法验证“OpenRoom”是否含有可能危害 Mac 或泄露隐私的恶意软件。

这是正确行为，不是 build 坏了。用 Developer ID 签名并公证需要付费的 Apple Developer 账号，
所以现在 release 是 adhoc 签名（`codesign --sign -`）、没有公证票。从网上下载的东西一律被
打上隔离属性，而 macOS 不会运行「被隔离且未公证」的代码。

差别就是一张证书。下载完直接能打开的项目——比如这份 workflow 的范本
[openusage](https://github.com/robinebers/openusage)——它的 DMG 由
`Developer ID Application: … (QC3D3H67V9)` 签名、一路串到 `Apple Root CA`，并且 staple 了
公证票。我们的是 `Signature=adhoc`、`TeamIdentifier=not set`、
`does not have a ticket stapled to it`。`release.yml` 里同样的签名、公证、staple 步骤早就
写好了，只是 secret 是空的所以被 skip 掉。代码一行都不用改，缺的只是去注册并把 secret 填上。

**自己编是最诚实的绕法，也是唯一不需要你关掉防护的做法**：`build-app.sh` 产出的 bundle
从来没有被隔离过，直接就能打开。

确实要跑下载回来的版本：**系统设置 → 隐私与安全性 → 安全性 →「仍要打开」**，或者

```bash
xattr -dr com.apple.quarantine /Applications/OpenRoom.app
```

跑之前先搞清楚它做了什么：隔离属性正是 macOS 会去检查下载代码的原因，去掉它等于对这个 app
关掉那道检查。对一个你读得懂源码、自己编出来的可执行文件这样做是合理的；把它当成处理别人
软件的习惯就不是。

**自动更新照样能用，而且这道关卡只需要过这一次。** Gatekeeper 拦的是**你**手动下载的那一
份；Sparkle 推来的更新不走那条路。`SUUpdateValidator` 的判据是「EdDSA 签名验过**或者**
codesign 与正在运行的 app 相符」，满足其一即可，所以 adhoc build 靠 EdDSA 签名就能更新。
随后 `SUFileManager` 会在安装前把解开的更新树上的 `com.apple.quarantine` 去掉。第一次安装
时过一次 Gatekeeper，代价就这么多。

（这个结论来自读 Sparkle 源码，不是在第二台机器上真的更新过。它是这条更新路径值得现在就接
起来、而不是等证书的理由，但跨机器的真实更新还没做过。）

### 维护者的一次性设置

1. 生成密钥对：用 Sparkle 自带的 `generate_keys`（`swift build` 之后在
   `native/OpenRoomApp/.build/artifacts` 底下，和 `generate_appcast` 同一份）。私钥进登录
   钥匙串、公钥印在 stdout；`generate_keys -x` 把私钥导出成文件，好贴给 CI。
2. 私钥存成 repository secret `SPARKLE_PRIVATE_KEY`。没有它，release workflow 会跳过整个
   appcast 并留一条 warning：这一版不会推给任何已安装的程序，它们停在原来的版本，直到有人
   手动下载。半张或没签名的 feed 比没有 feed 更糟，所以宁可什么都不发。
3. 公钥存成 repository secret `SPARKLE_PUBLIC_ED_KEY`。`build-app.sh` 从这个环境变量读，
   写进 Info.plist 的 `SUPublicEDKey`；release.yml 每次 tag build 都会传进去。这里没有
   默认值：填一个像模像样的 placeholder 会让坏掉的 build 看起来是配好的。两把钥匙必须同
   进同出，只给私钥会被直接拦下——那会签出一份 appcast，而对应的 app 没有东西可以验证它，
   错误只发生在用户的机器上，CI 这边一路绿灯。
4. GitHub Pages 打开，来源选 `gh-pages` 分支，appcast 就发在那里。workflow 用
   `peaceiris/actions-gh-pages` 推上去，`keep_files: true`，上面只放 `appcast.xml`，
   `.dmg` 留在 GitHub Release 上。
5. Apple 签名的 secret：`APPLE_CERTIFICATE`、`APPLE_CERTIFICATE_PASSWORD`（Developer ID
   Application 证书的 .p12，base64），以及公证要的 `APPLE_ID`、`APPLE_PASSWORD`、
   `APPLE_TEAM_ID`。

### 没有证书，自动更新就是废的

说白了：缺 Developer ID 证书和公证，CI 出来的就是 adhoc 签名的 build，**除了打包那台机器，
Gatekeeper 在每一台 Mac 上都会把它挡下来**。用户得自己
`xattr -dr com.apple.quarantine /Applications/OpenRoom.app` 才打得开，而自动更新装上去的
新版本照样会被挡——所以在实际使用上，这种情况下的自动更新等于没有。签名和公证不是"以后再
补的润色"，是自动更新能不能用的前提。少了哪一样，release workflow 都会印 warning 并照发，
不会假装一切正常。

上面第 1 到 4 步在这个 repo 已经做完了：密钥对存在、两半都是 repository secret、Pages 正在
服务 <https://sammylin.github.io/OpenRoom/appcast.xml>，feed 里有当前版本的签名条目。里面那
把公钥是 `WB8oDu+EGNgiVYDD5f+tcYo4OP7XWWJZSvvnyBQ8A/M=`，和出货 `Info.plist` 的
`SUPublicEDKey` 一致。只剩第 5 步的 Apple 签名 secret 还没有——而那一步买到的是「第一次安装
不用绕过 Gatekeeper」，不是「能不能更新」。

上面那份清单是 fork 出去的人要重做一遍的东西。

### 发版

推 tag 就发版，workflow 从 tag 的形状决定一切：

```bash
git tag v0.2.0 && git push origin v0.2.0                 # 正式版，推给所有人
git tag v0.2.0-beta.1 && git push origin v0.2.0-beta.1   # 带 '-' 的是预发布，只进 beta 频道
```

带 `-` 的 tag 同时是 GitHub prerelease，appcast 那一条也带 `--channel beta`，只有订了 beta
频道的安装收得到；干净的 tag 不带频道，那才是所有安装默认订的那一条。appcast 是**接着旧的
往上加**：workflow 先把 gh-pages 上已经发布的 feed 拉下来，`--maximum-versions 0` 不裁旧
条目，发布前数一遍条数，比拉下来的少就中止——掉一条就等于把某些旧版本的升级路径拿掉了。
feed 排在最后才发布，因为它指向的是 GitHub Release 的下载地址，不能比那些文件先上线。

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

实时节奏由 feeder 自己排：第 *k* 个 chunk 排在 `t0 + k × 100ms`，不依赖 `ffmpeg -re`——后者
的精度随版本漂移，同一段 3 秒音频在 ffmpeg 8 上要 2872ms，在 6.1.1 上只要 2484ms，而这个差
额会直接算进延迟数字里。ffmpeg 只负责解码和重采样。音频走的路径和麦克风完全一样，所以测出来
的延迟是真的，不是把模型离线批处理跑出来的那种假数字。
