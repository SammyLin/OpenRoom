import { useCallback, useRef, useState } from "react"
import { t } from "./i18n"
import { CHUNK_SAMPLES, SAMPLE_RATE, type AudioSource } from "./protocol"

/**
 * 音訊擷取。AudioContext 直接開在 16 kHz，重採樣交給瀏覽器（有正規的抗混疊）。
 *
 * 兩種來源：
 * - mic：一般麥克風。關掉 autoGainControl，因為 AGC 會一直改變音量基準，
 *   讓後端的能量門檻失去意義（舊版就是固定門檻對上會漂移的 AGC）。
 * - system：`getDisplayMedia` 的分頁／視窗音訊，用來錄 Google Meet、Teams 網頁版。
 *   Teams 桌面 app 抓不到，那需要 macOS 系統音訊擷取（尚未實作）。
 */
export function useAudioCapture() {
  const [level, setLevel] = useState(0)
  const [error, setError] = useState<string | null>(null)
  const ctxRef = useRef<AudioContext | null>(null)
  const streamRef = useRef<MediaStream | null>(null)
  const rafRef = useRef<number | null>(null)

  const stop = useCallback(() => {
    if (rafRef.current !== null) cancelAnimationFrame(rafRef.current)
    rafRef.current = null
    streamRef.current?.getTracks().forEach((t) => t.stop())
    streamRef.current = null
    void ctxRef.current?.close()
    ctxRef.current = null
    setLevel(0)
  }, [])

  /** onFrame 收到的是 1600 個 sample 的 s16le buffer（100 ms）。 */
  const start = useCallback(
    async (source: AudioSource, onFrame: (pcm: ArrayBuffer) => void) => {
      setError(null)
      try {
        const stream =
          source === "mic"
            ? await navigator.mediaDevices.getUserMedia({
                audio: {
                  channelCount: 1,
                  echoCancellation: true,
                  noiseSuppression: true,
                  autoGainControl: false,
                },
              })
            : await navigator.mediaDevices.getDisplayMedia({
                video: true, // 瀏覽器規定要選畫面才給得到音訊
                audio: { echoCancellation: false, noiseSuppression: false, autoGainControl: false },
              })

        if (stream.getAudioTracks().length === 0) {
          stream.getTracks().forEach((t) => t.stop())
          throw new Error(t("error.noAudioTrack"))
        }
        streamRef.current = stream

        const ctx = new AudioContext({ sampleRate: SAMPLE_RATE })
        ctxRef.current = ctx
        await ctx.audioWorklet.addModule("/pcm-worklet.js")

        const src = ctx.createMediaStreamSource(stream)
        const node = new AudioWorkletNode(ctx, "pcm-worklet")
        node.port.onmessage = (e: MessageEvent<ArrayBuffer>) => onFrame(e.data)

        const analyser = ctx.createAnalyser()
        analyser.fftSize = 512
        src.connect(analyser)
        src.connect(node)
        // worklet 不輸出聲音，但不接 destination 某些瀏覽器不會排程它
        node.connect(ctx.destination)

        const bins = new Float32Array(analyser.fftSize)
        let last = 0
        const tick = () => {
          analyser.getFloatTimeDomainData(bins)
          let sum = 0
          for (const v of bins) sum += v * v
          const rms = Math.sqrt(sum / bins.length)
          const next = Math.min(1, rms * 4)
          // 只在有意義的變化時 setState，避免每秒 60 次重繪整棵樹
          if (Math.abs(next - last) > 0.02) {
            last = next
            setLevel(next)
          }
          rafRef.current = requestAnimationFrame(tick)
        }
        rafRef.current = requestAnimationFrame(tick)

        // 使用者按瀏覽器自己的「停止分享」時要收得到
        stream.getAudioTracks()[0].addEventListener("ended", stop)
        return true
      } catch (e) {
        const msg = e instanceof Error ? e.message : String(e)
        setError(msg)
        stop()
        return false
      }
    },
    [stop],
  )

  return { start, stop, level, error, chunkSamples: CHUNK_SAMPLES }
}
