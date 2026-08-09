import { AlertTriangle, Activity, CheckCircle2, VolumeX } from "lucide-react"
import { useT } from "@/lib/i18n"
import type { Health } from "@/lib/useMeetingSocket"
import { cn } from "@/lib/utils"

/**
 * 「不准靜默失敗」的介面化身。
 *
 * 舊版每一種降級都是靜音的：ready 前的音訊靜默丟棄、佇列滿了靜默丟包、能量太低
 * 靜默跳過、模型改寫已定稿的字靜默替換。使用者只看到「什麼都沒發生」，無從判斷。
 * 這個面板把那些全部變成看得見的數字。
 */

function Row({
  label,
  value,
  tone = "normal",
  hint,
}: {
  label: string
  value: string
  tone?: "normal" | "warn" | "bad"
  hint?: string
}) {
  return (
    <div className="flex items-baseline justify-between gap-3 py-1.5">
      <span className="text-sm text-muted-foreground">
        {label}
        {hint && <span className="ml-1 text-xs text-muted-foreground/70">{hint}</span>}
      </span>
      <span
        className={cn(
          "font-mono text-sm tabular-nums",
          tone === "warn" && "text-amber-600 dark:text-amber-400",
          tone === "bad" && "text-destructive",
        )}
      >
        {value}
      </span>
    </div>
  )
}

export function HealthPanel({ health, engine }: { health: Health; engine: string | null }) {
  const t = useT()
  const clean =
    health.gaps === 0 && health.errors.length === 0 && health.droppedBeforeReady === 0
  const lost = health.lostMs / 1000

  return (
    <div className="flex h-full flex-col gap-5 overflow-y-auto p-5">
      <div>
        <h2 className="font-mono text-xs uppercase tracking-[0.14em] text-muted-foreground">
          {t("health.title")}
        </h2>
        <div
          className={cn(
            "mt-2 flex items-center gap-2 text-sm",
            clean ? "text-emerald-600 dark:text-emerald-400" : "text-destructive",
          )}
        >
          {clean ? (
            <CheckCircle2 className="size-4" aria-hidden />
          ) : (
            <AlertTriangle className="size-4" aria-hidden />
          )}
          {clean ? t("health.clean") : t("health.dirty")}
        </div>
      </div>

      <div className="divide-y divide-border/60 border-y border-border/60">
        <Row
          label={t("health.gaps")}
          value={
            health.gaps === 0
              ? "0"
              : t("health.gapsValue", { n: health.gaps, sec: lost.toFixed(1) })
          }
          tone={health.gaps > 0 ? "bad" : "normal"}
        />
        <Row
          label={t("health.backpressure")}
          value={`${health.backpressure}`}
          tone={health.backpressure > 0 ? "bad" : "normal"}
          hint={t("health.backpressureHint")}
        />
        <Row
          label={t("health.droppedBeforeReady")}
          value={`${health.droppedBeforeReady}`}
          tone={health.droppedBeforeReady > 0 ? "warn" : "normal"}
        />
        <Row label={t("health.noSpeech")} value={`${health.noSpeech}`} hint={t("health.noSpeechHint")} />
        <Row
          label={t("health.revisions")}
          value={`${health.revisions}`}
          hint={t("health.revisionsHint")}
          tone={health.revisions > 0 ? "warn" : "normal"}
        />
        <Row
          label={t("health.lastInfer")}
          value={health.lastInferMs === null ? "—" : `${health.lastInferMs} ms`}
          tone={health.lastInferMs !== null && health.lastInferMs > 800 ? "warn" : "normal"}
        />
        <Row label={t("health.engine")} value={engine ?? "—"} />
      </div>

      {health.speakerErrors.length > 0 && (
        <div className="space-y-2">
          <h3 className="font-mono text-xs uppercase tracking-[0.14em] text-muted-foreground">
            {t("health.speakerSection")}
          </h3>
          {health.speakerErrors.map((e, i) => (
            <div key={`${e.code}-${i}`} className="rounded-md border bg-muted/40 p-3">
              <p className="font-mono text-xs text-muted-foreground">{e.code}</p>
              <p className="mt-1 text-sm">{e.message}</p>
            </div>
          ))}
        </div>
      )}

      {health.errors.length > 0 && (
        <div className="space-y-2">
          <h3 className="font-mono text-xs uppercase tracking-[0.14em] text-destructive">
            {t("health.errorsSection")}
          </h3>
          {health.errors.map((e, i) => (
            <div
              key={`${e.code}-${i}`}
              className="rounded-md border border-destructive/40 bg-destructive/5 p-3"
            >
              <p className="font-mono text-xs text-destructive">{e.code}</p>
              <p className="mt-1 text-sm">{e.message}</p>
            </div>
          ))}
        </div>
      )}

      <div className="mt-auto space-y-2 text-xs text-muted-foreground">
        <p className="flex items-center gap-1.5">
          <Activity className="size-3.5" aria-hidden />
          {t("health.latencyTarget")}
        </p>
        <p className="flex items-center gap-1.5">
          <VolumeX className="size-3.5" aria-hidden />
          {t("health.speakerNote")}
        </p>
      </div>
    </div>
  )
}
