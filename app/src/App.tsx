import { useCallback, useEffect, useRef, useState } from "react"
import { Download, Radio, Square } from "lucide-react"
import { Button } from "@/components/ui/button"
import { HealthPanel } from "@/components/HealthPanel"
import { InsightPanel } from "@/components/InsightPanel"
import { SetupScreen } from "@/components/SetupScreen"
import { TranscriptStream } from "@/components/TranscriptStream"
import {
  SCENARIOS,
  formatClock,
  groupSegments,
  speakerNames,
  type AudioSource,
  type Scenario,
} from "@/lib/protocol"
import { useAudioCapture } from "@/lib/useAudioCapture"
import { useMeetingSocket } from "@/lib/useMeetingSocket"

const WS_BASE = import.meta.env.VITE_WS_BASE ?? "ws://127.0.0.1:8000"

export default function App() {
  const [source, setSource] = useState<AudioSource>("system")
  const [scenario, setScenario] = useState<Scenario>("discussion")
  const [busy, setBusy] = useState(false)
  const capture = useAudioCapture()
  const socket = useMeetingSocket(WS_BASE)
  const sendRef = useRef(socket.sendAudio)
  sendRef.current = socket.sendAudio

  const start = useCallback(async () => {
    setBusy(true)
    const meetingId = `m${Date.now()}`
    const connected = await socket.connect(meetingId, source, scenario)
    if (!connected) {
      setBusy(false)
      return
    }
    // 擷取先開起來，音訊在 ready 之前會被 socket 層緩衝，不會靜靜消失
    const capturing = await capture.start(source, (pcm) => sendRef.current(pcm))
    // 擷取失敗（權限被拒、沒有音訊軌）卻繼續顯示「錄製中」，就是舊版那種
    // 「看起來在收音，其實什麼都沒有」。收掉連線，讓錯誤回到設定畫面。
    if (!capturing) socket.stop()
    setBusy(false)
  }, [capture, socket, source, scenario])

  const stop = useCallback(() => {
    capture.stop()
    socket.stop()
  }, [capture, socket])

  useEffect(() => {
    if (socket.phase === "failed") capture.stop()
  }, [socket.phase, capture])

  const exportTranscript = useCallback(() => {
    // 匯出跟畫面看到的一樣是段落，不是一行一秒的碎片
    const names = speakerNames(socket.turns)
    const body = groupSegments(socket.segments, socket.turns)
      .map((s) => {
        const who = names.get(s.speaker)
        return `[${formatClock(s.startMs)}]${who ? ` ${who}：` : " "}${s.text}`
      })
      .join("\n\n")
    const blob = new Blob([`# 會議逐字稿\n\n${body}\n`], {
      type: "text/markdown;charset=utf-8",
    })
    const a = document.createElement("a")
    a.href = URL.createObjectURL(blob)
    a.download = `huddle-${new Date().toISOString().slice(0, 19).replace(/[:T]/g, "")}.md`
    a.click()
    URL.revokeObjectURL(a.href)
  }, [socket.segments, socket.turns])

  // 一句逐字稿都沒有就結束 = 這場根本沒開始。回設定畫面並帶著錯誤，不要停在一個
  // 空白的「已停止」畫面讓人猜發生什麼事。
  const nothingRecorded = socket.segments.length === 0
  if (
    socket.phase === "idle" ||
    ((socket.phase === "failed" || socket.phase === "stopped") && nothingRecorded)
  ) {
    return (
      <SetupScreen
        source={source}
        onSource={setSource}
        scenario={scenario}
        onScenario={setScenario}
        onStart={start}
        busy={busy}
        error={capture.error ?? socket.health.errors.at(-1)?.message ?? null}
      />
    )
  }

  const live = socket.phase === "live"
  const warming = socket.phase === "warming" || socket.phase === "connecting"
  const clean =
    socket.health.gaps === 0 &&
    socket.health.errors.length === 0 &&
    socket.health.droppedBeforeReady === 0

  return (
    <div className="flex h-svh flex-col">
      <header className="flex shrink-0 items-center gap-4 border-b px-5 py-3">
        <div className="flex items-center gap-2">
          <Radio
            className={live ? "size-4 text-red-500" : "size-4 text-muted-foreground"}
            aria-hidden
          />
          <span className="font-mono text-xs uppercase tracking-[0.14em]">
            {live ? "錄製中" : warming ? "預熱中" : "已停止"}
          </span>
        </div>

        <span className="font-mono text-sm tabular-nums text-muted-foreground">
          {formatClock(socket.audioMs)}
        </span>

        {/* 音量表：看得到聲音進來，才知道「有沒有在收音」 */}
        <div
          className="h-1.5 w-28 overflow-hidden rounded-full bg-muted"
          role="meter"
          aria-label="輸入音量"
          aria-valuenow={Math.round(capture.level * 100)}
        >
          <div
            className="h-full rounded-full bg-primary transition-[width] duration-75"
            style={{ width: `${Math.round(capture.level * 100)}%` }}
          />
        </div>

        <div className="ml-auto flex items-center gap-2">
          <Button
            variant="ghost"
            size="sm"
            onClick={exportTranscript}
            disabled={socket.segments.length === 0}
          >
            <Download className="size-4" aria-hidden />
            匯出
          </Button>
          <Button variant={live ? "destructive" : "secondary"} size="sm" onClick={stop} disabled={!live}>
            <Square className="size-4" aria-hidden />
            停止
          </Button>
        </div>
      </header>

      <div className="flex min-h-0 flex-1">
        <main className="min-w-0 flex-1">
          <TranscriptStream
            segments={socket.segments}
            partial={socket.partial}
            warming={warming}
            turns={socket.turns}
          />
        </main>
        <aside className="hidden w-96 shrink-0 flex-col border-l lg:flex">
          <div className="min-h-0 flex-1">
            <InsightPanel
              insights={socket.insights}
              analysing={socket.analysing}
              quietRounds={socket.quietRounds}
              health={socket.health}
              scenarioLabel={SCENARIOS.find((s) => s.id === scenario)?.label ?? ""}
            />
          </div>
          {/* 管線健康擺在收合區：平常不該佔版面，但出事時必須找得到 */}
          <details className="shrink-0 border-t">
            <summary className="cursor-pointer px-4 py-2.5 font-mono text-xs uppercase tracking-[0.14em] text-muted-foreground hover:text-foreground">
              管線健康
              {!clean && <span className="ml-2 text-destructive">有問題</span>}
            </summary>
            <div className="max-h-72 overflow-y-auto border-t">
              <HealthPanel health={socket.health} engine={socket.engine} />
            </div>
          </details>
        </aside>
      </div>
    </div>
  )
}
