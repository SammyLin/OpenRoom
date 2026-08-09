import { AlertTriangle, Mic, MonitorSpeaker } from "lucide-react"
import { Button } from "@/components/ui/button"
import { cn } from "@/lib/utils"
import { SCENARIOS, type AudioSource, type Scenario } from "@/lib/protocol"

const SOURCES: {
  id: AudioSource
  icon: typeof Mic
  title: string
  detail: string
  caveat?: string
}[] = [
  {
    id: "system",
    icon: MonitorSpeaker,
    title: "分頁音訊",
    detail: "錄 Google Meet、Teams 網頁版。分享時要勾「同時分享分頁音訊」。",
    caveat: "Teams 桌面 app 抓不到，那需要 macOS 系統音訊擷取（還沒做）。",
  },
  {
    id: "mic",
    icon: Mic,
    title: "麥克風",
    detail: "實體會議室，一支麥克風收全場。",
  },
]

export function SetupScreen({
  source,
  onSource,
  scenario,
  onScenario,
  onStart,
  busy,
  error,
}: {
  source: AudioSource
  onSource: (s: AudioSource) => void
  scenario: Scenario
  onScenario: (s: Scenario) => void
  onStart: () => void
  busy: boolean
  error: string | null
}) {
  return (
    <div className="mx-auto flex min-h-svh w-full max-w-2xl flex-col justify-center gap-8 px-6 py-16">
      <div className="space-y-3">
        <p className="font-mono text-xs uppercase tracking-[0.18em] text-muted-foreground">
          OpenRoom
        </p>
        <h1 className="text-3xl font-semibold tracking-tight">開始一場會議</h1>
        <p className="max-w-md text-sm text-muted-foreground">
          逐字稿在你的機器上產生，音訊不離開這台電腦。
        </p>
      </div>

      <fieldset className="space-y-3">
        <legend className="font-mono text-xs uppercase tracking-[0.14em] text-muted-foreground">
          這是什麼場合
        </legend>
        <p className="text-sm text-muted-foreground">
          場合決定分析怎麼做，逐字稿不受影響。
        </p>
        <div className="grid gap-2 sm:grid-cols-2">
          {SCENARIOS.map((s) => {
            const active = scenario === s.id
            return (
              <button
                key={s.id}
                type="button"
                onClick={() => onScenario(s.id)}
                aria-pressed={active}
                className={cn(
                  "rounded-lg border p-3 text-left transition-colors",
                  "focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-ring",
                  active ? "border-primary bg-accent" : "border-border hover:bg-accent/50",
                )}
              >
                <span className="block text-sm font-medium">{s.label}</span>
                <span className="mt-1 block text-xs text-muted-foreground">{s.detail}</span>
              </button>
            )
          })}
        </div>
      </fieldset>

      <fieldset className="grid gap-3">
        <legend className="mb-3 font-mono text-xs uppercase tracking-[0.14em] text-muted-foreground">
          聲音從哪裡來
        </legend>
        {SOURCES.map((s) => {
          const Icon = s.icon
          const active = source === s.id
          return (
            <button
              key={s.id}
              type="button"
              onClick={() => onSource(s.id)}
              aria-pressed={active}
              className={cn(
                "flex gap-4 rounded-lg border p-4 text-left transition-colors",
                "focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-ring",
                active ? "border-primary bg-accent" : "border-border hover:bg-accent/50",
              )}
            >
              <Icon className="mt-0.5 size-5 shrink-0 text-muted-foreground" aria-hidden />
              <span className="space-y-1">
                <span className="block font-medium">{s.title}</span>
                <span className="block text-sm text-muted-foreground">{s.detail}</span>
                {s.caveat && (
                  <span className="block text-xs text-muted-foreground/80">{s.caveat}</span>
                )}
              </span>
            </button>
          )
        })}
      </fieldset>

      {error && (
        <div className="flex gap-3 rounded-lg border border-destructive/40 bg-destructive/5 p-4">
          <AlertTriangle className="mt-0.5 size-4 shrink-0 text-destructive" aria-hidden />
          <p className="text-sm text-destructive">{error}</p>
        </div>
      )}

      <div className="space-y-3">
        <Button size="lg" onClick={onStart} disabled={busy} className="w-full sm:w-auto">
          {busy ? "連線中…" : "開始"}
        </Button>
        <p className="font-mono text-xs text-muted-foreground">
          後端要先跑起來：<code>python -m openroom.server</code>
          <br />
          第一次啟動要預熱模型約 45 秒，預熱完才會開始收音——這是刻意的，
          否則開場那段會進黑洞。
        </p>
      </div>
    </div>
  )
}
