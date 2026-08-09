import { useCallback, useRef, useState } from "react"
import { t } from "./i18n"
import {
  CHUNK_MS,
  SAMPLE_RATE,
  frameWithHeader,
  type AudioSource,
  type InsightItem,
  type Scenario,
  type ServerEvent,
  type SpeakerTurn,
} from "./protocol"

export type Phase = "idle" | "connecting" | "warming" | "live" | "stopped" | "failed"

export interface Segment {
  id: string
  text: string
  speaker: string
  startMs: number
  endMs: number
}

export interface Insight {
  id: string
  headline: string
  items: InsightItem[]
  questions: string[]
  atMs: number
  latencyMs: number
}

/** 任何降級都要看得見——這些數字直接餵給 UI 的健康面板。 */
export interface Health {
  noSpeech: number
  gaps: number
  lostMs: number
  backpressure: number
  revisions: number
  errors: { code: string; message: string; fatal: boolean }[]
  lastInferMs: number | null
  droppedBeforeReady: number
  insightErrors: { code: string; message: string }[]
  speakerErrors: { code: string; message: string }[]
}

const EMPTY_HEALTH: Health = {
  noSpeech: 0,
  gaps: 0,
  lostMs: 0,
  backpressure: 0,
  revisions: 0,
  errors: [],
  lastInferMs: null,
  droppedBeforeReady: 0,
  insightErrors: [],
  speakerErrors: [],
}

export function useMeetingSocket(wsBase: string) {
  const [phase, setPhase] = useState<Phase>("idle")
  const [segments, setSegments] = useState<Segment[]>([])
  const [partial, setPartial] = useState("")
  const [health, setHealth] = useState<Health>(EMPTY_HEALTH)
  const [engine, setEngine] = useState<string | null>(null)
  const [warmupSec, setWarmupSec] = useState<number | null>(null)
  const [audioMs, setAudioMs] = useState(0)
  const [insights, setInsights] = useState<Insight[]>([])
  // 講者分離是回填的：整份 turns 每次被新的一份取代，不是累加
  const [turns, setTurns] = useState<SpeakerTurn[]>([])
  const [speakers, setSpeakers] = useState(0)
  const [analysing, setAnalysing] = useState(false)
  const [quietRounds, setQuietRounds] = useState(0)

  const wsRef = useRef<WebSocket | null>(null)
  const seqRef = useRef(0)
  // ready 之前不准送音訊。舊版在這裡靜默丟棄，是「不會收音」的成因之一。
  const readyRef = useRef(false)
  // 但「擋下來」不等於「丟掉」——擋掉的是開場白。協定寫的是「要嘛緩衝，要嘛回
  // error」，所以這裡緩衝，ready 之後照 seq 順序補送。
  const pendingRef = useRef<ArrayBuffer[]>([])

  const flushPending = useCallback((ws: WebSocket) => {
    for (const pcm of pendingRef.current) {
      const seq = seqRef.current++
      ws.send(frameWithHeader(seq, seq * CHUNK_MS, pcm))
    }
    pendingRef.current = []
  }, [])

  const handleEvent = useCallback((ev: ServerEvent) => {
    switch (ev.type) {
      case "ready":
        readyRef.current = true
        if (wsRef.current) flushPending(wsRef.current)  // 預熱期間收到的開場白補送
        setEngine(ev.engine)
        setWarmupSec(ev.warmup_sec ?? null)
        setPhase("live")
        break
      case "final":
        setSegments((prev) => [
          ...prev,
          {
            id: `${ev.start_ms}-${prev.length}`,
            text: ev.text,
            speaker: ev.speaker,
            startMs: ev.start_ms ?? 0,
            endMs: ev.end_ms ?? 0,
          },
        ])
        setPartial("")
        setAudioMs(ev.end_ms ?? 0)
        setHealth((h) => ({ ...h, lastInferMs: ev.infer_ms ?? h.lastInferMs }))
        break
      case "partial":
        setPartial(ev.text)
        setAudioMs(ev.end_ms ?? 0)
        setHealth((h) => ({ ...h, lastInferMs: ev.infer_ms ?? h.lastInferMs }))
        break
      case "revise":
        // 模型回頭改寫已定稿的內容。不能默默換掉，UI 要看得到次數。
        setHealth((h) => ({ ...h, revisions: h.revisions + 1 }))
        break
      case "no_speech":
        setAudioMs(ev.end_ms ?? 0)
        setHealth((h) => ({ ...h, noSpeech: h.noSpeech + 1 }))
        break
      case "gap":
        setHealth((h) => ({
          ...h,
          gaps: h.gaps + 1,
          lostMs: h.lostMs + ev.lost_ms,
          backpressure: h.backpressure + (ev.reason === "asr_backpressure" ? 1 : 0),
        }))
        break
      case "error":
        setHealth((h) => ({
          ...h,
          errors: [...h.errors, { code: ev.code, message: ev.message, fatal: ev.fatal }],
        }))
        if (ev.fatal) setPhase("failed")
        break
      case "insight_pending":
        setAnalysing(true)
        break
      case "insight":
        setInsights((prev) => [
          {
            id: `${ev.at_ms}-${prev.length}`,
            headline: ev.headline,
            items: ev.items ?? [],
            questions: ev.questions ?? [],
            atMs: ev.at_ms,
            latencyMs: ev.latency_ms,
          },
          ...prev, // 最新的在最上面：開會時看的是「現在」
        ])
        setAnalysing(false)
        break
      case "insight_none":
        // 跑完了，只是沒有新東西可講。不是錯誤，但 UI 得收手。
        setAnalysing(false)
        setQuietRounds((n) => n + 1)
        break
      case "insight_error":
        setAnalysing(false)
        setHealth((h) => ({
          ...h,
          insightErrors: [...h.insightErrors, { code: ev.code, message: ev.message }],
        }))
        break
      case "speaker_turns":
        setTurns(ev.turns)
        setSpeakers(ev.speakers)
        break
      case "speaker_error":
        setHealth((h) => ({
          ...h,
          speakerErrors: [...h.speakerErrors, { code: ev.code, message: ev.message }],
        }))
        break
      case "done":
        setPhase("stopped")
        setAnalysing(false)
        break
    }
  }, [flushPending])

  const connect = useCallback(
    (meetingId: string, source: AudioSource, scenario: Scenario) =>
      new Promise<boolean>((resolve) => {
        setPhase("connecting")
        setSegments([])
        setPartial("")
        setHealth(EMPTY_HEALTH)
        setInsights([])
        setTurns([])
        setSpeakers(0)
        setQuietRounds(0)
        seqRef.current = 0
        readyRef.current = false
        pendingRef.current = []

        const ws = new WebSocket(`${wsBase}/ws/${meetingId}`)
        ws.binaryType = "arraybuffer"
        wsRef.current = ws

        ws.onopen = () => {
          setPhase("warming")
          ws.send(
            JSON.stringify({
              type: "start",
              sample_rate: SAMPLE_RATE,
              channels: 1,
              format: "s16le",
              source,
              scenario,
              engine: "qwen-mlx",
            }),
          )
          resolve(true)
        }
        ws.onmessage = (e) => {
          if (typeof e.data !== "string") return
          handleEvent(JSON.parse(e.data) as ServerEvent)
        }
        ws.onerror = () => {
          setHealth((h) => ({
            ...h,
            errors: [
              ...h.errors,
              {
                code: "ws_error",
                message: t("error.wsFailed", { base: wsBase }),
                fatal: true,
              },
            ],
          }))
          setPhase("failed")
          resolve(false)
        }
        ws.onclose = () => {
          setPhase((p) => (p === "failed" ? p : "stopped"))
          // 最後一道保險：連線沒了就不可能再收到分析結果，別讓 UI 停在「分析中」
          setAnalysing(false)
        }
      }),
    [wsBase, handleEvent],
  )

  const sendAudio = useCallback((pcm: ArrayBuffer) => {
    const ws = wsRef.current
    if (!ws || ws.readyState === WebSocket.CLOSING || ws.readyState === WebSocket.CLOSED) {
      // 連線沒了才是真的丟。舊版在這裡回 false 就結束，沒人知道。
      setHealth((h) => ({ ...h, droppedBeforeReady: h.droppedBeforeReady + 1 }))
      return
    }
    if (!readyRef.current) {
      // ponytail: 上限 600 幀（60 秒），冷啟動預熱實測 46 秒。真的滿了就丟，
      // 而且要看得見——但那代表預熱異常，不是正常路徑。
      if (pendingRef.current.length >= 600) {
        setHealth((h) => ({ ...h, droppedBeforeReady: h.droppedBeforeReady + 1 }))
        return
      }
      pendingRef.current.push(pcm)
      return
    }
    const seq = seqRef.current++
    ws.send(frameWithHeader(seq, seq * CHUNK_MS, pcm))
  }, [])

  const stop = useCallback(() => {
    const ws = wsRef.current
    if (ws?.readyState === WebSocket.OPEN) ws.send(JSON.stringify({ type: "stop" }))
  }, [])

  return {
    phase, segments, partial, health, engine, warmupSec, audioMs,
    insights, analysing, quietRounds, turns, speakers, connect, sendAudio, stop,
  }
}
