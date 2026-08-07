import { useCallback, useRef, useState } from "react"
import {
  CHUNK_MS,
  SAMPLE_RATE,
  frameWithHeader,
  type AudioSource,
  type InsightItem,
  type Scenario,
  type ServerEvent,
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
  const [analysing, setAnalysing] = useState(false)

  const wsRef = useRef<WebSocket | null>(null)
  const seqRef = useRef(0)
  // ready 之前不准送音訊。舊版在這裡靜默丟棄，是「不會收音」的成因之一，
  // 所以這裡用 ref 硬擋，並且把擋掉的次數顯示在 UI 上。
  const readyRef = useRef(false)

  const handleEvent = useCallback((ev: ServerEvent) => {
    switch (ev.type) {
      case "ready":
        readyRef.current = true
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
      case "insight_error":
        setAnalysing(false)
        setHealth((h) => ({
          ...h,
          insightErrors: [...h.insightErrors, { code: ev.code, message: ev.message }],
        }))
        break
      case "done":
        setPhase("stopped")
        setAnalysing(false)
        break
    }
  }, [])

  const connect = useCallback(
    (meetingId: string, source: AudioSource, scenario: Scenario) =>
      new Promise<boolean>((resolve) => {
        setPhase("connecting")
        setSegments([])
        setPartial("")
        setHealth(EMPTY_HEALTH)
        setInsights([])
        seqRef.current = 0
        readyRef.current = false

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
                message: `連不上 ${wsBase}。後端有跑嗎？（python -m huddle.server）`,
                fatal: true,
              },
            ],
          }))
          setPhase("failed")
          resolve(false)
        }
        ws.onclose = () => {
          setPhase((p) => (p === "failed" ? p : "stopped"))
        }
      }),
    [wsBase, handleEvent],
  )

  const sendAudio = useCallback((pcm: ArrayBuffer) => {
    const ws = wsRef.current
    if (!ws || ws.readyState !== WebSocket.OPEN || !readyRef.current) {
      // 沒送出去就是丟了。舊版在這裡回 false 就結束，沒人知道。
      setHealth((h) => ({ ...h, droppedBeforeReady: h.droppedBeforeReady + 1 }))
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
    insights, analysing, connect, sendAudio, stop,
  }
}
