import { AlertTriangle, Mic, MonitorSpeaker } from "lucide-react"
import { Button } from "@/components/ui/button"
import { LanguagePicker } from "@/components/LanguagePicker"
import { useT, type MessageKey } from "@/lib/i18n"
import { cn } from "@/lib/utils"
import { SCENARIOS, type AudioSource, type Scenario } from "@/lib/protocol"

// 文案在 i18n.ts 的 source.* key，這裡只留圖示與「有沒有但書」
const SOURCES: { id: AudioSource; icon: typeof Mic; caveat?: MessageKey }[] = [
  { id: "system", icon: MonitorSpeaker, caveat: "source.system.caveat" },
  { id: "mic", icon: Mic },
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
  const t = useT()

  return (
    <div className="mx-auto flex min-h-svh w-full max-w-2xl flex-col justify-center gap-8 px-6 py-16">
      <div className="space-y-3">
        <div className="flex items-center justify-between gap-4">
          <p className="font-mono text-xs uppercase tracking-[0.18em] text-muted-foreground">
            OpenRoom
          </p>
          <LanguagePicker className="-mr-2" />
        </div>
        <h1 className="text-3xl font-semibold tracking-tight">{t("setup.heading")}</h1>
        <p className="max-w-md text-sm text-muted-foreground">{t("setup.tagline")}</p>
      </div>

      <fieldset className="space-y-3">
        <legend className="font-mono text-xs uppercase tracking-[0.14em] text-muted-foreground">
          {t("setup.scenarioLegend")}
        </legend>
        <p className="text-sm text-muted-foreground">{t("setup.scenarioHint")}</p>
        <div className="grid gap-2 sm:grid-cols-2">
          {SCENARIOS.map((s) => {
            const active = scenario === s
            return (
              <button
                key={s}
                type="button"
                onClick={() => onScenario(s)}
                aria-pressed={active}
                className={cn(
                  "rounded-lg border p-3 text-left transition-colors",
                  "focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-ring",
                  active ? "border-primary bg-accent" : "border-border hover:bg-accent/50",
                )}
              >
                <span className="block text-sm font-medium">{t(`scenario.${s}.label`)}</span>
                <span className="mt-1 block text-xs text-muted-foreground">
                  {t(`scenario.${s}.detail`)}
                </span>
              </button>
            )
          })}
        </div>
      </fieldset>

      <fieldset className="grid gap-3">
        <legend className="mb-3 font-mono text-xs uppercase tracking-[0.14em] text-muted-foreground">
          {t("setup.sourceLegend")}
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
                <span className="block font-medium">{t(`source.${s.id}.title`)}</span>
                <span className="block text-sm text-muted-foreground">
                  {t(`source.${s.id}.detail`)}
                </span>
                {s.caveat && (
                  <span className="block text-xs text-muted-foreground/80">{t(s.caveat)}</span>
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
          {busy ? t("setup.connecting") : t("setup.start")}
        </Button>
        <p className="font-mono text-xs text-muted-foreground">
          {t("setup.backendHint")}
          <code>python -m openroom.server</code>
          <br />
          {t("setup.warmupNote")}
        </p>
      </div>
    </div>
  )
}
