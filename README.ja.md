# OpenRoom

[English](README.md) · [繁體中文](README.zh-TW.md) · [简体中文](README.zh-CN.md) · 日本語

ローカル完結のライブ会議文字起こし。Apple Silicon の Mac、同時に 1 会議のみ。

旧バージョン(`github.com/SammyLin/huddle` にある Python/FastAPI/React のプロジェクト)の
書き直しである。旧バージョンを殺したのは言語でもフレームワークでもなく、**あらゆる失敗経路が
無言だった**ことだ。セッションの準備前に届いた音声は何も言わずに捨てられ、開いていない
ソケットへの送信は黙って false を返し、エンジン名のタイプミスは黙ってダミーデータ生成器に
フォールバックし、ハードコードされた閾値を下回るエネルギーは黙ってスキップされた。ユーザーに
見えたのは「音声を拾わないし、分析もしない」だけで、どこが壊れているのか知る手段はなかった。

だからこのバージョンの第一原則はモデルの品質ではない:

> **無言の劣化をさせない。** すべての劣化・破棄・スキップは、目に見えるイベントを発行しなければならない。

## 決定事項

| 項目 | 決定 |
|---|---|
| 形態 | 単一マシンの個人用ツール。同時に 1 会議、Apple Silicon 限定 |
| バックエンド | Python 3.11 |
| フロントエンド | Tailwind + shadcn(UX を再設計) |
| ASR | Qwen3-ASR MLX(オンデバイス) |
| 話者分離 | pyannote.audio、**ASR とは別プロセス** |
| 言語 | 中国語と英語をどちらも一級市民として扱う。文中での混在も含む |
| 音声ソース | macOS のシステム音声キャプチャ(Teams / Google Meet を録れる) |
| ストレージ | `runs/` 以下のファイル。当初は SQLite と決めていた。マシン 1 台で 1 会議、一度書いて一度読むだけなら、データベースは何も生まない |
| やらないこと | Postgres、Docker、Cloud Run、JWT、CORS、レート制限、シミュレータ |

### 合格ライン(旧 PRD §4 NFR から引き継ぎ)

| 指標 | 目標 |
|---|---|
| partial レイテンシ | < 800 ms P95 |
| final レイテンシ | < 3 s P95 |
| 話者交代の検出レイテンシ | < 2 s |
| DER | < 15% |
| 繁体字中国語 WER | < 12% |

旧 PRD の「同時 10 会議以上」は無効とする。GPU 1 基のマシン 1 台では不可能だし、その必要もない。

## 構築順序

1. ~~**eval ハーネス**~~ 完了
2. ~~音声 → WS → ディスクに書き出し~~ 完了(WS 側は完了、macOS のシステム音声キャプチャは未着手)
3. ~~Qwen3-ASR MLX(別プロセス)~~ レイテンシのゲートは通過、**WER は未通過**(29.4%、ゲートは 12%)
4. ~~フロントエンド: 文字起こし + ヘルスパネル~~ 完了
5. ~~ライブ分析レイヤー(interview / discussion)~~ 完了、文字起こしのエクスポートを含む
6. **実際の会議で動かす** ← 現在地。中国語 WER 37.6%、レイテンシはゲートを通過、読める水準にはある
7. WER: `context` で固有名詞を与える、`finalization_mode`(マージ層での境界の重複はすでに修正済み、2pp の価値がある)
8. ~~pyannote による話者分離(別プロセス)~~ 完了、DER は未計測
9. ~~macOS のシステム音声キャプチャ~~ 完了: `native/openroom-capture`。ScreenCaptureKit が
   システム出力を掴むので(ブラウザのタブ共有に依存しない。つまり Teams のデスクトップアプリも
   キャプチャできる)、`docs/protocol.md` そのままの WS クライアントとしてバックエンドに直結する。
   初回起動時はシステム設定 > プライバシーとセキュリティ > 画面とシステム音声の収録 での
   許可が必要。

もともと最後に予定していた LLM レイヤーを前倒しした。文字起こしは素材にすぎず、
**「会議が続いている最中に、裏付け資料と追加で聞くべき質問を出す」ことがこのツールの存在理由**
であり、実際に動かして初めて文字起こしの精度が本当はどれだけ必要なのかが分かるからだ。

そして WER の作り込みが実運用の**後ろ**に来るのは、あのゲートが旧 PRD からのコピーであって、
要件として計測されたものではないからだ。WER 32% の壊れた英語の文字起こしでも、分析レイヤーは
使える裏付け資料を出せる。よって主要な指標はインサイトの品質であり、WER は診断用の値でしかない。
インサイトの品質にラベルを付けるにはラベルを付ける対象が要る。イベントをディスクに書き出して
いる(`runs/<timestamp>-<meeting_id>/events.jsonl`)のはそのためだ。

## 実行方法

```bash
uv venv --python 3.11 && source .venv/bin/activate
uv pip install -e '.[eval,dev,diarize]' 'mlx-qwen3-asr>=0.3.5'

export HF_TOKEN=hf_...                    # the diarization model is a gated repo, see below
python -m openroom.server --language en     # omit --language to auto-detect (use this for mixed zh/en)

cd app && npm install && npm run dev      # frontend → http://localhost:5173
```

サーバーは先にモデルをウォームアップし(初回は Metal カーネルのコンパイルが走り、およそ 46 秒)、
**ウォームアップが終わってから初めて `ready` を送る**。それより前に送られた音声は黙って飲み込まれる
のではなく `error` が返る。フロントエンドは `ready` まで破棄ではなく**バッファリング**し、その後
seq 順で再送する。抑え込まれるのは冒頭の発言であり、一度落とせば戻らない。

セッションごとに `runs/<timestamp>-<meeting_id>/` へ書き出す: `audio.raw`(生の PCM)、
`events.jsonl`(フロントエンドに送った**すべての**イベント。`_wall_ms` と `infer_ms` 付き)、
`transcript.txt`。SQLite は使わない。マシン 1 台、同時 1 会議、一度書いて一度読むだけだからだ。

フロントエンドで「システム音声」を選ぶとブラウザの画面共有ダイアログを通ることになり、
**「タブの音声を共有」に必ずチェックを入れること**。入れないと音声トラックが存在せず、その場合は
黙って無音を録り続けるのではなくエラーになる。

### 話者分離

pyannote は独立したプロセスで動き、「そこまでの音声全体」に対して再実行する。そのため話者の
同一性が時間をまたいで保たれる。このモデルは **gated repo** である。まず
<https://huggingface.co/pyannote/speaker-diarization-community-1> で規約に同意し、その上で
`HF_TOKEN` を設定すること。設定がなければ、話者ラベルが黙って失われるのではなく
`speaker_error` が返る。

```bash
python -m openroom.server --no-diarize            # turn off when measuring ASR latency, both sides fight over the same GPU
python -m openroom.server --diarize-idle-ratio 12 # more conservative: steadier ASR, later speaker labels
```

**話者ラベルは後追いで埋められる**ため、文字起こしより数十秒遅れて届く。これはリアルタイム性を
同一性の一貫性と引き換えにした結果だ。計測値は `docs/measurements.md` にある。

### 分析レイヤー

一緒に聞きながら材料を足していく。何を探すかはシナリオが決める。`interview` は誤った回答と
掘り下げる価値のある質問を拾い、`discussion` は固有名詞と背景を補う。LLM はデフォルトで
`claude` CLI の print モードを経由する(このマシンには `ANTHROPIC_API_KEY` がないので Claude Code
のログインを借りている)。したがって 1 ラウンドごとに金がかかるため、トリガーは絞ってある。
400 文字たまり、かつ前回のラウンドから 25 秒経ってから初めて走り、前回のラウンドが返ってきて
いなければスキップする。

```bash
python -m openroom.server --scenario interview --llm-model claude-sonnet-5
python -m openroom.server --no-web-search   # stop it from searching the web to verify
```

分析は常に音声キャプチャの後ろに並ぶ(`nice -n 15`、バックグラウンドタスク、さらに ASR が 6 秒
以上遅れたらラウンドごと譲る)。スキップのたびに `insight_error` を送るので、理由は UI から見える。

**LLM プロバイダは差し替え可能**で、環境変数 `OPENROOM_LLM_PROVIDER` で選ぶ
(デフォルトは `claude-cli`、挙動は従来どおり):

| provider | 説明 | 関連する環境変数 |
|---|---|---|
| `claude-cli` | デフォルト、`claude -p ... --output-format json` |(なし)|
| `cli` | 互換の CLI に差し替える(`-p` / `--output-format json` の契約が同じもの)| `OPENROOM_LLM_CLI`(ツール名。例: `codex`、`gemini`) |
| `anthropic-api` | Anthropic Messages API を直接呼ぶ | `ANTHROPIC_API_KEY` |
| `ollama` | ローカルの Ollama サーバーを呼ぶ | `OLLAMA_HOST`(デフォルト `http://localhost:11434`)、`OPENROOM_OLLAMA_MODEL`(デフォルト `llama3.1`) |

```bash
OPENROOM_LLM_PROVIDER=anthropic-api ANTHROPIC_API_KEY=sk-ant-... python -m openroom.server
OPENROOM_LLM_PROVIDER=ollama OPENROOM_OLLAMA_MODEL=llama3.1 python -m openroom.server
```

4 つのプロバイダはいずれも同じ振る舞いをする。どんな失敗でも `insight_error` を送り、黙って
空の結果を返すものは 1 つもない。

## 自動アップデート

配布物は `native/OpenRoomApp/build-app.sh` が組む `OpenRoom.app`(Xcode project ではなく
shell script 1 本)であり、これはフロントエンドでしかない。ASR と話者分離は今までどおり
このリポジトリの Python バックエンドが動かす。その `.app` は**自分でアップデートを確認する**。
Sparkle 2 を使う。macOS には App Store の外で更新を配る仕組みが無く、自前で書けば結局
署名検証を自前で書くことになるからだ。

- フィードは <https://sammylin.github.io/OpenRoom/appcast.xml>(`gh-pages` ブランチを
  GitHub Pages が配信する)。`Info.plist` の `SUFeedURL` がここを指す。
- **初回起動で黙って外に出ることはない。** `SUEnableAutomaticChecks` は意図的に書いていない。
  書けば Sparkle は初回の確認をスキップし、一度も聞かずに外へ問い合わせを始める。同意を
  Info.plist が代わりに押すのではなく、初回起動時に本人へ聞かせる。有効にした後の確認間隔は
  `SUScheduledCheckInterval` の 86400 秒(24 時間)。メニューの「アップデートを確認…」は
  いつでも手動で叩ける。
- **検証できない更新は入らない。** ダウンロードは EdDSA 署名で検証し、検証に失敗したものは
  適用を拒否する。公開鍵(`Info.plist` の `SUPublicEDKey`)を持たないビルドでは updater を
  そもそも起動しない。メニュー項目は「アップデート不可 — このビルドには更新キーがありません」
  と表示して無効になる。押しても何も起きない「アップデートを確認」は無言の劣化だからだ。
  `SPARKLE_PUBLIC_ED_KEY` が未設定のとき build-app.sh は placeholder を書いたりせず、
  警告を出したうえで `SUPublicEDKey` の行ごと省く。

### ダウンロードしたビルドは開かない

リリースに置いてあるのは `.dmg` で、その中身を macOS は開こうとしない。

> 「OpenRoom」は開けません — "OpenRoom" に Mac に害を及ぼしたりプライバシーを侵害したり
> するマルウェアが含まれていないことを Apple は確認できませんでした。

これはビルドが壊れているのではなく、正しい挙動だ。Developer ID による署名と公証には有料の
Apple Developer アカウントが要るため、現在のリリースは adhoc 署名(`codesign --sign -`)で
公証チケットも無い。インターネットから落としたものには隔離属性が付き、macOS は「隔離されて
いて未公証」のコードを実行しない。

違いは証明書一枚だ。何もせずに開くプロジェクト——たとえばこのワークフローの手本にした
[openusage](https://github.com/robinebers/openusage)——の DMG は
`Developer ID Application: … (QC3D3H67V9)` で署名され `Apple Root CA` まで連なり、公証
チケットが staple されている。こちらは `Signature=adhoc`、`TeamIdentifier=not set`、
`does not have a ticket stapled to it` と出る。`release.yml` は同じ署名・公証・staple の
手順をすでに持っていて、secret が無いから skip されているだけだ。コードを変える必要はない。

**自分でビルドするのが一番正直な回避策**であり、保護を切らずに済む唯一の方法でもある。
`build-app.sh` が作る bundle は一度も隔離されていないので、そのまま開く。

それでもダウンロード版を動かすなら、**システム設定 → プライバシーとセキュリティ →
セキュリティ →「このまま開く」**、または

```bash
xattr -dr com.apple.quarantine /Applications/OpenRoom.app
```

実行する前に何をしているか理解しておくこと。隔離属性こそが macOS にダウンロードしたコードを
検査させている当のものであり、外すというのはこの app に対してその検査を切るということだ。
ソースを読める、自分でビルドしたバイナリに対してなら妥当な判断だが、他人のソフトウェア一般に
対する習慣にしてよいものではない。

**自動アップデートは動く。この関門を越えるのは最初の一度だけだ。** Gatekeeper が見るのは
**自分でダウンロードした**コピーであって、Sparkle が持ってくる更新はそこを通らない。
`SUUpdateValidator` は「EdDSA 署名が検証できた **または** コードサインが実行中の app と
一致した」のどちらかで受理するので、adhoc ビルドは EdDSA 署名だけで更新できる。その後
`SUFileManager` が展開した更新ツリーから `com.apple.quarantine` を外してからインストール
する。初回インストールで一度 Gatekeeper を越えれば、コストはそれで終わりだ。

(これは Sparkle のソースを読んだ結論であって、二台目のマシンで実際に更新を観測したもので
はない。証明書を待たずに更新経路を今つないだ理由がこれだが、マシンをまたいだ実際の更新は
まだ行っていない。)

### メンテナ側の一度きりの設定

1. Sparkle の `generate_keys` で EdDSA の鍵ペアを作る。秘密鍵はキーチェーンに入り、
   `generate_keys -x` で書き出せる。公開鍵は標準出力に出る。
2. 書き出した秘密鍵を repository secret `SPARKLE_PRIVATE_KEY` に入れる。release.yml は
   これを stdin 経由で `generate_appcast` に渡す(argv に置かない。argv は runner 上の
   どのプロセスからも読める)。この secret が無いときは appcast を一切書かない。既存の
   インストールにそのリリースは出てこない。中途半端なフィードを出すより何も出さない方が
   マシだからだ。
3. 公開鍵は repository secret `SPARKLE_PUBLIC_ED_KEY` に入れる。build-app.sh がこの環境
   変数を読んで `Info.plist` の `SUPublicEDKey` に書き、release.yml はタグビルドのたびに
   それを渡す。ここが空のままだと `SUPublicEDKey` の無い `.app` が出荷され、そのビルドは
   永久にアップデートできない。二つの鍵は揃っていなければ拒否される。秘密鍵だけがある状態
   では、検証する手段を持たない `.app` に向けて appcast に署名することになり、失敗するのは
   ユーザーのマシンの上だけで、CI からは成功に見える。
4. `gh-pages` ブランチで GitHub Pages を有効にする(Settings > Pages、source をそのブランチに)。
   ブランチ自体は最初のリリースが作る。Pages が有効になっていなければフィードの URL は 404 を
   返し、インストール済みの `.app` は毎回アップデート確認に失敗する。
5. Apple の署名用 secret を入れる。`APPLE_CERTIFICATE`(Developer ID Application 証明書の
   `.p12` を base64 したもの)、`APPLE_CERTIFICATE_PASSWORD`、そして公証用に `APPLE_ID`、
   `APPLE_PASSWORD`、`APPLE_TEAM_ID`。

**Developer ID 証明書と公証が無ければ、この自動アップデートは実用上まったく意味がない。**
`APPLE_CERTIFICATE` が無いとき release.yml は警告を出したうえで adhoc 署名のまま出荷し、
そのビルドは**ビルドしたマシン以外のすべての Mac で Gatekeeper に止められる**。証明書が
あっても公証が無ければ初回起動が止められる。そして Sparkle が新しい版を落としてきても、
止められる `.app` はやはり止められる。つまり証明書と公証が揃うまで、配布版のアップデート
経路は成立しない。これは設定漏れの類ではなく、有料の Apple Developer Program が要るという
話であり、この 2 つが揃うまでのリリースは「手で落として `xattr -dr com.apple.quarantine` を
叩ける人だけが使えるもの」だと考えてよい。

上の 1〜4 はこのリポジトリでは設定済みだ。鍵ペアは存在し、両方が repository secret に入って
いて、Pages が <https://sammylin.github.io/OpenRoom/appcast.xml> を配信しており、フィードには
現行リリースの署名付きアイテムがある。そこに入っている公開鍵は
`WB8oDu+EGNgiVYDD5f+tcYo4OP7XWWJZSvvnyBQ8A/M=` で、出荷される `Info.plist` の
`SUPublicEDKey` と一致する。残っているのは 5 の Apple 署名用 secret だけで、それが買えるのは
「初回インストールで Gatekeeper を迂回せずに済むこと」であって、更新できるかどうかではない。

上のリストは、fork した人がやり直すことになる作業だ。

### リリースの出し方

タグを push するだけでよい。バージョンもチャンネルもタグの形から決まる。

```bash
git tag v0.2.0 && git push origin v0.2.0                 # 全員に配る
git tag v0.2.0-beta.1 && git push origin v0.2.0-beta.1   # beta チャンネルだけに配る
```

`-` を含むタグは prerelease として扱われ、その 1 つの判定が GitHub Release の prerelease
フラグと `generate_appcast --channel beta` の両方を決める。beta チャンネルを購読していない
インストールに `v0.2.0-beta.1` は出てこない。

appcast は公開済みのフィードを持ち越したうえで書き直し、`--maximum-versions 0` で古い項目を
黙って間引かせない。今回の項目に EdDSA 署名が付いていない場合、あるいは項目数が減った場合、
workflow はフィードを発行せずにその場で失敗する。フィードの発行は GitHub Release への
アップロードの**後**に行う。フィードが指す先のファイルは、フィードが公開される時点で
存在していなければならない。

## eval ハーネス

数字がなければ書き直しで何かが良くなったのかを言えない。だからハーネスはプロダクトコードより
先に作った。

```bash
uv venv --python 3.11 && source .venv/bin/activate
uv pip install -e '.[eval]'

# fetch corpus: YouTube video → 16k mono wav + official subtitles as ground truth
python -m eval.corpus fetch 'https://www.youtube.com/watch?v=...'

# list the corpora already fetched
python -m eval.corpus list

# feed audio into the WS at real-time pace (same path the microphone takes), measure P95 latency
python -m eval.feed corpus/<slug>/audio.wav --ws ws://127.0.0.1:8000/ws/test

# compute WER (per-character for CJK, per-word for Latin, no language flag needed; comparing only the first N seconds requires reference.jsonl)
python -m eval.metrics wer corpus/<slug>/reference.jsonl hypothesis.txt --until-sec 120
```

ASR を計測するときは `--no-analyst` でサーバーを起動すること。1 回の実行ごとに LLM の代金を
払わずに済む。

**手動字幕は必ずしも書き起こしではない。翻訳のこともある**(実際にやった。英語のインタビューに
中国語字幕が付いていて、出てきた 80% の WER は完全に偽物だった)。`fetch` は動画の言語と
突き合わせて警告を出す。`--langs` で字幕言語の優先順を指定できる。

コーパスは `corpus/` に置き、バージョン管理下には入れない。

### テスト素材

- **GitLab Unfiltered**(<https://www.youtube.com/@GitLabUnfiltered/videos>)— 実際の複数人会議が
  1 本のミックストラックに入っている。話者分離が相手にするのはまさにこれだ。公式字幕は WER の
  ground truth として使えるが、**英語 WER はプロダクトの指標ではない**。
- **塞掐 Side Chat E417**(`6h6VsrclFTI`)— 中国語のインタビュー、中英混在、**手動の zh-TW 字幕**
  (人間による書き起こしで、自動生成より信頼できる)。繁体字中国語 WER のベースラインはこれ。
- **AMI Corpus** — 話者アノテーションが完備されており、DER の客観的なベースラインになる。
  話者分離がそこまで進んだ段階で接続する。

リアルタイムのペース配分は feeder 自身が行う。*k* 番目のチャンクを `t0 + k × 100ms` に送る
スケジュールで、`ffmpeg -re` には頼らない。あの精度はバージョンによって動く——同じ 3 秒の音声
が ffmpeg 8 では 2872ms、6.1.1 では 2484ms で流れ切ってしまい、その差はそのままレイテンシの
数字に混入する。ffmpeg はデコードとリサンプルだけを担当する。音声はマイクとまったく同じ経路を
通るので、計測しているレイテンシは本物であり、モデルをオフラインでバッチ実行して得られる偽の
数字ではない。
