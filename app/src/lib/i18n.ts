import { useSyncExternalStore } from "react"

/**
 * 四種語言、五十來個字串，不值得裝一套 i18n 框架。
 *
 * 英文是來源語言：`en` 的 key 就是 MessageKey，其他語言宣告成 Record<MessageKey, string>，
 * 所以少一個 key 或打錯字是 TypeScript 錯誤，不是執行期悄悄掉回英文。
 * 執行期沒有 fallback 這條路，因為型別保證它到不了。
 */

export const LOCALES = ["en", "zh-Hant", "zh-Hans", "ja"] as const
export type Locale = (typeof LOCALES)[number]

/** 選單只寫該語言自己的名字：看得懂那一項的人正是要選它的人。 */
export const LOCALE_NAMES: Record<Locale, string> = {
  en: "English",
  "zh-Hant": "繁體中文",
  "zh-Hans": "简体中文",
  ja: "日本語",
}

const en = {
  "lang.label": "Language",

  "setup.heading": "Start a meeting",
  "setup.tagline":
    "The transcript is produced on your machine. The audio never leaves this computer.",
  "setup.scenarioLegend": "What kind of session",
  "setup.scenarioHint":
    "The scenario decides how analysis is done. The transcript is unaffected.",
  "setup.sourceLegend": "Where the audio comes from",
  "setup.connecting": "Connecting…",
  "setup.start": "Start",
  "setup.backendHint": "The backend has to be running first: ",
  "setup.warmupNote":
    "The first launch spends about 45 seconds warming the model up, and capture starts only after that — deliberately, otherwise the opening disappears into a black hole.",

  "source.system.title": "Tab audio",
  "source.system.detail":
    "For Google Meet and Teams in the browser. When you share, tick “Also share tab audio”.",
  "source.system.caveat":
    "The Teams desktop app cannot be captured this way. That needs macOS system audio capture, which is not built yet.",
  "source.mic.title": "Microphone",
  "source.mic.detail": "A physical meeting room, one microphone for everyone.",

  "scenario.discussion.label": "Discussion",
  "scenario.discussion.detail":
    "Fills in background on the tools, terms and numbers being mentioned, and flags claims worth checking.",
  "scenario.interview.label": "Interview",
  "scenario.interview.detail":
    "Judges whether the candidate's answers hold up, where they are vague, and what to ask next.",

  "status.live": "Recording",
  "status.warming": "Warming up",
  "status.stopped": "Stopped",
  "meter.input": "Input level",
  "action.export": "Export",
  "action.stop": "Stop",

  "export.title": "Meeting transcript",
  "export.speakerLabel": "{name}: ",
  "speaker.n": "Speaker {n}",

  "warm.aria": "Warming the model up",
  "warm.title": "Warming the model up",
  "warm.detail":
    "The first inference has to compile GPU kernels, about 45 seconds. Capture starts only after that, so you will not miss the opening.",
  "transcript.empty": "Listening. Start talking and the transcript will appear.",

  "insight.header": "Live analysis · {scenario}",
  "insight.analysing": "Analysing",
  "insight.empty":
    "Analysis runs by itself once enough conversation has piled up. Short fragments yield nothing, so it does not run on every sentence.",
  "insight.quiet":
    "{n} more analysis rounds had nothing new to add (duplicates are not listed again)",
  "insight.error": "Analysis failed ({code}): {message}",
  "insight.questions": "Worth asking",
  "insight.latency": "{sec}s",
  "insight.srKind": "{label}: ",
  "insight.kind.context": "Background",
  "insight.kind.fact": "Looked up",
  "insight.kind.correction": "Wrong claim",
  "insight.kind.risk": "Watch out",

  "health.title": "Pipeline health",
  "health.problem": "Problems",
  "health.clean": "No audio lost",
  "health.dirty": "Some audio never reached the model",
  "health.gaps": "Audio gaps",
  "health.gapsValue": "{n} ({sec}s)",
  "health.backpressure": "Inference falling behind",
  "health.backpressureHint": "dropped",
  "health.droppedBeforeReady": "Dropped, could not send",
  "health.noSpeech": "Judged silent",
  "health.noSpeechHint": "segments",
  "health.revisions": "Rewritten after the fact",
  "health.revisionsHint": "times",
  "health.lastInfer": "Last inference",
  "health.engine": "Engine",
  "health.speakerSection": "Speaker separation",
  "health.errorsSection": "Errors",
  "health.latencyTarget": "Latency targets: partial < 800 ms, final < 3 s",
  "health.speakerNote":
    "Speaker labels are backfilled, tens of seconds behind the transcript",

  "error.wsFailed":
    "Cannot reach {base}. Is the backend running? (python -m openroom.server)",
  "error.noAudioTrack":
    "This source has no audio track. When sharing a tab, tick “Also share tab audio”.",
} as const

export type MessageKey = keyof typeof en

const zhHant: Record<MessageKey, string> = {
  "lang.label": "語言",

  "setup.heading": "開始一場會議",
  "setup.tagline": "逐字稿在你的機器上產生，音訊不離開這台電腦。",
  "setup.scenarioLegend": "這是什麼場合",
  "setup.scenarioHint": "場合決定分析怎麼做，逐字稿不受影響。",
  "setup.sourceLegend": "聲音從哪裡來",
  "setup.connecting": "連線中…",
  "setup.start": "開始",
  "setup.backendHint": "後端要先跑起來：",
  "setup.warmupNote":
    "第一次啟動要預熱模型約 45 秒，預熱完才會開始收音——這是刻意的，否則開場那段會進黑洞。",

  "source.system.title": "分頁音訊",
  "source.system.detail": "錄 Google Meet、Teams 網頁版。分享時要勾「同時分享分頁音訊」。",
  "source.system.caveat": "Teams 桌面 app 抓不到，那需要 macOS 系統音訊擷取（還沒做）。",
  "source.mic.title": "麥克風",
  "source.mic.detail": "實體會議室，一支麥克風收全場。",

  "scenario.discussion.label": "討論會議",
  "scenario.discussion.detail": "補上被提到的工具、名詞、數字的背景資料，標出值得查證的說法。",
  "scenario.interview.label": "面試",
  "scenario.interview.detail": "判斷受訪者的答案是否正確、哪裡含糊，並建議接下來該追問什麼。",

  "status.live": "錄製中",
  "status.warming": "預熱中",
  "status.stopped": "已停止",
  "meter.input": "輸入音量",
  "action.export": "匯出",
  "action.stop": "停止",

  "export.title": "會議逐字稿",
  "export.speakerLabel": "{name}：",
  "speaker.n": "講者 {n}",

  "warm.aria": "模型預熱中",
  "warm.title": "正在預熱模型",
  "warm.detail": "第一次推論要編譯 GPU kernel，約 45 秒。預熱完才開始收音，所以你不會漏掉開場。",
  "transcript.empty": "在聽了。開始講話就會出現逐字稿。",

  "insight.header": "即時分析 · {scenario}",
  "insight.analysing": "分析中",
  "insight.empty": "累積一段對話之後會自動分析。太短的內容分析不出東西，所以不會每句話都跑。",
  "insight.quiet": "另有 {n} 輪分析沒有新內容可補（重複的不會再列一次）",
  "insight.error": "分析失敗（{code}）：{message}",
  "insight.questions": "可以追問",
  "insight.latency": "{sec} 秒",
  "insight.srKind": "{label}：",
  "insight.kind.context": "背景",
  "insight.kind.fact": "查到的資料",
  "insight.kind.correction": "說法有誤",
  "insight.kind.risk": "要注意",

  "health.title": "管線健康",
  "health.problem": "有問題",
  "health.clean": "沒有丟失任何音訊",
  "health.dirty": "有音訊沒進到模型",
  "health.gaps": "音訊缺口",
  "health.gapsValue": "{n}（{sec} 秒）",
  "health.backpressure": "推論來不及",
  "health.backpressureHint": "丟包",
  "health.droppedBeforeReady": "送不出去丟棄",
  "health.noSpeech": "判定為靜音",
  "health.noSpeechHint": "段",
  "health.revisions": "回頭改寫",
  "health.revisionsHint": "次",
  "health.lastInfer": "最近一次推論",
  "health.engine": "引擎",
  "health.speakerSection": "講者分離",
  "health.errorsSection": "錯誤",
  "health.latencyTarget": "延遲目標：partial < 800 ms、final < 3 s",
  "health.speakerNote": "講者標籤是回填的，比逐字稿晚數十秒才會標上",

  "error.wsFailed": "連不上 {base}。後端有跑嗎？（python -m openroom.server）",
  "error.noAudioTrack": "這個來源沒有音訊軌。分享分頁時要勾選「同時分享分頁音訊」。",
}

const zhHans: Record<MessageKey, string> = {
  "lang.label": "语言",

  "setup.heading": "开始一场会议",
  "setup.tagline": "逐字稿在你的机器上产生，音频不离开这台电脑。",
  "setup.scenarioLegend": "这是什么场合",
  "setup.scenarioHint": "场合决定分析怎么做，逐字稿不受影响。",
  "setup.sourceLegend": "声音从哪里来",
  "setup.connecting": "连接中…",
  "setup.start": "开始",
  "setup.backendHint": "后端要先跑起来：",
  "setup.warmupNote":
    "第一次启动要预热模型约 45 秒，预热完才会开始收音——这是刻意的，否则开场那段会进黑洞。",

  "source.system.title": "标签页音频",
  "source.system.detail": "录 Google Meet、Teams 网页版。共享时要勾「同时共享标签页音频」。",
  "source.system.caveat": "Teams 桌面 app 抓不到，那需要 macOS 系统音频采集（还没做）。",
  "source.mic.title": "麦克风",
  "source.mic.detail": "实体会议室，一支麦克风收全场。",

  "scenario.discussion.label": "讨论会议",
  "scenario.discussion.detail": "补上被提到的工具、名词、数字的背景资料，标出值得查证的说法。",
  "scenario.interview.label": "面试",
  "scenario.interview.detail": "判断受访者的答案是否正确、哪里含糊，并建议接下来该追问什么。",

  "status.live": "录制中",
  "status.warming": "预热中",
  "status.stopped": "已停止",
  "meter.input": "输入音量",
  "action.export": "导出",
  "action.stop": "停止",

  "export.title": "会议逐字稿",
  "export.speakerLabel": "{name}：",
  "speaker.n": "讲者 {n}",

  "warm.aria": "模型预热中",
  "warm.title": "正在预热模型",
  "warm.detail": "第一次推理要编译 GPU kernel，约 45 秒。预热完才开始收音，所以你不会漏掉开场。",
  "transcript.empty": "在听了。开始讲话就会出现逐字稿。",

  "insight.header": "实时分析 · {scenario}",
  "insight.analysing": "分析中",
  "insight.empty": "累积一段对话之后会自动分析。太短的内容分析不出东西，所以不会每句话都跑。",
  "insight.quiet": "另有 {n} 轮分析没有新内容可补（重复的不会再列一次）",
  "insight.error": "分析失败（{code}）：{message}",
  "insight.questions": "可以追问",
  "insight.latency": "{sec} 秒",
  "insight.srKind": "{label}：",
  "insight.kind.context": "背景",
  "insight.kind.fact": "查到的资料",
  "insight.kind.correction": "说法有误",
  "insight.kind.risk": "要注意",

  "health.title": "管线健康",
  "health.problem": "有问题",
  "health.clean": "没有丢失任何音频",
  "health.dirty": "有音频没进到模型",
  "health.gaps": "音频缺口",
  "health.gapsValue": "{n}（{sec} 秒）",
  "health.backpressure": "推理来不及",
  "health.backpressureHint": "丢包",
  "health.droppedBeforeReady": "送不出去丢弃",
  "health.noSpeech": "判定为静音",
  "health.noSpeechHint": "段",
  "health.revisions": "回头改写",
  "health.revisionsHint": "次",
  "health.lastInfer": "最近一次推理",
  "health.engine": "引擎",
  "health.speakerSection": "讲者分离",
  "health.errorsSection": "错误",
  "health.latencyTarget": "延迟目标：partial < 800 ms、final < 3 s",
  "health.speakerNote": "讲者标签是回填的，比逐字稿晚数十秒才会标上",

  "error.wsFailed": "连不上 {base}。后端有跑吗？（python -m openroom.server）",
  "error.noAudioTrack": "这个来源没有音频轨。共享标签页时要勾选「同时共享标签页音频」。",
}

const ja: Record<MessageKey, string> = {
  "lang.label": "言語",

  "setup.heading": "会議を始める",
  "setup.tagline": "文字起こしはこのマシン上で行われ、音声はこのコンピュータから出ません。",
  "setup.scenarioLegend": "どんな場面か",
  "setup.scenarioHint": "場面によって分析の仕方が変わります。文字起こしには影響しません。",
  "setup.sourceLegend": "音声の入力元",
  "setup.connecting": "接続中…",
  "setup.start": "開始",
  "setup.backendHint": "先にバックエンドを起動してください：",
  "setup.warmupNote":
    "初回起動時はモデルのウォームアップに約 45 秒かかり、それが終わってから収音を始めます。意図的な仕様です。そうしないと冒頭がまるごと消えます。",

  "source.system.title": "タブの音声",
  "source.system.detail":
    "ブラウザ版の Google Meet や Teams 向け。共有するときは「タブの音声も共有する」にチェックを入れてください。",
  "source.system.caveat":
    "Teams のデスクトップ app は取得できません。macOS のシステム音声キャプチャが必要ですが、まだ実装していません。",
  "source.mic.title": "マイク",
  "source.mic.detail": "実際の会議室で、マイク 1 本で全員を拾います。",

  "scenario.discussion.label": "ディスカッション",
  "scenario.discussion.detail":
    "話に出たツール・用語・数字の背景を補い、裏取りすべき主張を指摘します。",
  "scenario.interview.label": "面接",
  "scenario.interview.detail":
    "候補者の回答が正しいか、どこが曖昧かを判断し、次に何を掘り下げるべきかを提案します。",

  "status.live": "録音中",
  "status.warming": "ウォームアップ中",
  "status.stopped": "停止済み",
  "meter.input": "入力レベル",
  "action.export": "エクスポート",
  "action.stop": "停止",

  "export.title": "会議の文字起こし",
  "export.speakerLabel": "{name}：",
  "speaker.n": "話者 {n}",

  "warm.aria": "モデルをウォームアップ中",
  "warm.title": "モデルをウォームアップしています",
  "warm.detail":
    "初回の推論で GPU カーネルをコンパイルするため約 45 秒かかります。終わってから収音を始めるので、冒頭を取り逃しません。",
  "transcript.empty": "待機中です。話し始めると文字起こしが表示されます。",

  "insight.header": "リアルタイム分析 · {scenario}",
  "insight.analysing": "分析中",
  "insight.empty":
    "会話がある程度たまると自動で分析します。短すぎる内容からは何も出ないため、一文ごとには実行しません。",
  "insight.quiet": "他に {n} 回の分析では新しく補える内容がありませんでした（重複は再掲しません）",
  "insight.error": "分析に失敗しました（{code}）：{message}",
  "insight.questions": "聞いてみる価値のあること",
  "insight.latency": "{sec} 秒",
  "insight.srKind": "{label}：",
  "insight.kind.context": "背景",
  "insight.kind.fact": "調べた情報",
  "insight.kind.correction": "誤った主張",
  "insight.kind.risk": "要注意",

  "health.title": "パイプラインの状態",
  "health.problem": "問題あり",
  "health.clean": "音声の欠落なし",
  "health.dirty": "モデルに届かなかった音声があります",
  "health.gaps": "音声の欠落",
  "health.gapsValue": "{n}（{sec} 秒）",
  "health.backpressure": "推論が追いつかない",
  "health.backpressureHint": "ドロップ",
  "health.droppedBeforeReady": "送信できず破棄",
  "health.noSpeech": "無音と判定",
  "health.noSpeechHint": "区間",
  "health.revisions": "後から書き換え",
  "health.revisionsHint": "回",
  "health.lastInfer": "直近の推論",
  "health.engine": "エンジン",
  "health.speakerSection": "話者分離",
  "health.errorsSection": "エラー",
  "health.latencyTarget": "レイテンシ目標：partial < 800 ms、final < 3 s",
  "health.speakerNote": "話者ラベルは後追いで付与され、文字起こしより数十秒遅れます",

  "error.wsFailed":
    "{base} に接続できません。バックエンドは起動していますか？（python -m openroom.server）",
  "error.noAudioTrack":
    "この入力元には音声トラックがありません。タブを共有するときは「タブの音声も共有する」にチェックを入れてください。",
}

const MESSAGES: Record<Locale, Record<MessageKey, string>> = {
  en,
  "zh-Hant": zhHant,
  "zh-Hans": zhHans,
  ja,
}

const STORAGE_KEY = "openroom.locale"

/** zh 沒帶地區時分不出簡繁，與其猜錯不如讓它落到下一個偏好語言。 */
function fromTag(tag: string): Locale | null {
  const s = tag.toLowerCase()
  if (s === "ja" || s.startsWith("ja-")) return "ja"
  if (s === "en" || s.startsWith("en-")) return "en"
  if (s === "zh" || s.startsWith("zh-")) {
    if (/hant|-tw|-hk|-mo/.test(s)) return "zh-Hant"
    if (/hans|-cn|-sg/.test(s)) return "zh-Hans"
  }
  return null
}

function detect(): Locale {
  const saved = localStorage.getItem(STORAGE_KEY)
  if (saved && (LOCALES as readonly string[]).includes(saved)) return saved as Locale
  const tags = navigator.languages?.length ? navigator.languages : [navigator.language]
  for (const tag of tags) {
    const hit = fromTag(tag)
    if (hit) return hit
  }
  return "en"
}

let current = detect()
document.documentElement.lang = current

const subscribers = new Set<() => void>()

function subscribe(fn: () => void) {
  subscribers.add(fn)
  return () => void subscribers.delete(fn)
}

export function getLocale(): Locale {
  return current
}

export function setLocale(next: Locale) {
  current = next
  localStorage.setItem(STORAGE_KEY, next)
  document.documentElement.lang = next
  for (const fn of subscribers) fn()
}

/**
 * 沒帶到的 {var} 就原樣留在畫面上——看得見的破字比默默吞掉好找。
 * 元件不要直接叫這個，用 useT()，否則換語言時不會重繪。
 */
export function t(key: MessageKey, vars?: Record<string, string | number>): string {
  const s = MESSAGES[current][key]
  return vars ? s.replace(/\{(\w+)\}/g, (m, k: string) => (k in vars ? String(vars[k]) : m)) : s
}

export function useLocale(): Locale {
  return useSyncExternalStore(subscribe, getLocale)
}

export function useT(): typeof t {
  useLocale()
  return t
}
