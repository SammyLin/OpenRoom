// docs/protocol.md 的 TypeScript 端。改這裡就要改那份文件。

export const SAMPLE_RATE = 16_000
export const CHUNK_MS = 100
export const CHUNK_SAMPLES = (SAMPLE_RATE * CHUNK_MS) / 1000 // 1600

export type AudioSource = "mic" | "system"
export type Scenario = "interview" | "discussion"

export const SCENARIOS: { id: Scenario; label: string; detail: string }[] = [
  {
    id: "discussion",
    label: "討論會議",
    detail: "補上被提到的工具、名詞、數字的背景資料，標出值得查證的說法。",
  },
  {
    id: "interview",
    label: "面試",
    detail: "判斷受訪者的答案是否正確、哪裡含糊，並建議接下來該追問什麼。",
  },
]

export interface InsightItem {
  kind: "fact" | "correction" | "context" | "risk"
  text: string
}

export interface StartMessage {
  type: "start"
  sample_rate: number
  channels: 1
  format: "s16le"
  source: AudioSource | "eval"
  engine: string
  scenario: Scenario
}

interface Base {
  end_ms?: number
  start_ms?: number
}

export type ServerEvent =
  | ({ type: "ready"; engine: string; model?: string; warmup_sec?: number } & Base)
  | ({ type: "partial"; text: string; speaker: string; confidence?: number; infer_ms?: number } & Base)
  | ({ type: "final"; text: string; speaker: string; confidence?: number; infer_ms?: number } & Base)
  | ({ type: "revise"; from_char: number; dropped: string; text: string } & Base)
  | ({ type: "no_speech"; rms: number; reason: string } & Base)
  | ({ type: "gap"; expected_seq: number; got_seq: number; lost_ms: number; reason?: string } & Base)
  | ({ type: "error"; code: string; message: string; fatal: boolean } & Base)
  | ({ type: "done"; audio_ms: number; text?: string } & Base)
  | ({
      type: "insight"
      scenario: Scenario
      headline: string
      items: InsightItem[]
      questions: string[]
      at_ms: number
      latency_ms: number
    } & Base)
  | ({ type: "insight_error"; code: string; message: string } & Base)
  | ({ type: "insight_pending"; scenario: Scenario; at_ms: number } & Base)

/** 8 byte header：seq (uint32 BE) + audio_ts_ms (uint32 BE)，後面接 PCM。 */
export function frameWithHeader(seq: number, audioTsMs: number, pcm: ArrayBuffer): ArrayBuffer {
  const out = new ArrayBuffer(8 + pcm.byteLength)
  const view = new DataView(out)
  view.setUint32(0, seq, false)
  view.setUint32(4, audioTsMs, false)
  new Uint8Array(out, 8).set(new Uint8Array(pcm))
  return out
}

// 一個 final 只是一秒 chunk 的增量，照著畫就是一行一秒，讀起來不成句。
// 合併成段落：夠長而且結在句尾就換段，太長就硬換。
const PARA_MIN_MS = 6_000
const PARA_MAX_MS = 20_000
const SENTENCE_END = /[.。!！?？][")'」』）]?$/
const CJK = /[㐀-鿿豈-﫿　-〿]/

/** 接起兩段文字。中文不加空白；英文的句號如果後面接小寫，是模型亂斷的，拿掉。 */
function join(left: string, right: string): string {
  if (CJK.test(left) || CJK.test(right)) return left + right
  const trimmed = /[a-z]/.test(right[0] ?? "") ? left.replace(/\.$/, "") : left
  return `${trimmed} ${right}`
}

export function groupSegments<T extends { text: string; startMs: number; endMs: number }>(
  segments: T[],
): T[] {
  const out: T[] = []
  for (const s of segments) {
    const last = out[out.length - 1]
    const openable =
      last &&
      !(
        last.endMs - last.startMs >= PARA_MAX_MS ||
        (last.endMs - last.startMs >= PARA_MIN_MS && SENTENCE_END.test(last.text.trim()))
      )
    if (openable) {
      out[out.length - 1] = { ...last, text: join(last.text, s.text), endMs: s.endMs }
    } else {
      out.push({ ...s })
    }
  }
  return out
}

export function formatClock(ms: number): string {
  const total = Math.floor(ms / 1000)
  const h = Math.floor(total / 3600)
  const m = Math.floor((total % 3600) / 60)
  const s = total % 60
  const mm = `${m}`.padStart(2, "0")
  const ss = `${s}`.padStart(2, "0")
  return h > 0 ? `${h}:${mm}:${ss}` : `${mm}:${ss}`
}
