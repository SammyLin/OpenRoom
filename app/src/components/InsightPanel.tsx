import { AlertTriangle, BookOpen, CircleHelp, Loader2, TriangleAlert, XCircle } from "lucide-react"
import { formatClock, type InsightItem } from "@/lib/protocol"
import type { Health, Insight } from "@/lib/useMeetingSocket"
import { cn } from "@/lib/utils"

/**
 * 產品的重點面板：一邊聽，一邊給補充資料與追問建議。
 *
 * 最新的一則放在最上面——開會的時候要看的是「現在在講什麼」，不是從頭捲。
 */

const KIND: Record<InsightItem["kind"], { icon: typeof BookOpen; label: string; tone: string }> = {
  context: { icon: BookOpen, label: "背景", tone: "text-muted-foreground" },
  fact: { icon: BookOpen, label: "查到的資料", tone: "text-sky-600 dark:text-sky-400" },
  correction: { icon: XCircle, label: "說法有誤", tone: "text-destructive" },
  risk: { icon: TriangleAlert, label: "要注意", tone: "text-amber-600 dark:text-amber-400" },
}

function Card({ insight }: { insight: Insight }) {
  return (
    <article className="space-y-3 rounded-lg border bg-card p-4">
      <div className="flex items-baseline justify-between gap-2">
        <h3 className="text-sm font-medium leading-snug">{insight.headline}</h3>
        <time className="shrink-0 font-mono text-xs tabular-nums text-muted-foreground">
          {formatClock(insight.atMs)}
        </time>
      </div>

      {insight.items.length > 0 && (
        <ul className="space-y-2">
          {insight.items.map((item, i) => {
            const meta = KIND[item.kind] ?? KIND.context
            const Icon = meta.icon
            return (
              <li key={i} className="flex gap-2.5">
                <Icon className={cn("mt-0.5 size-3.5 shrink-0", meta.tone)} aria-hidden />
                <span className="text-sm leading-relaxed text-muted-foreground">
                  <span className="sr-only">{meta.label}：</span>
                  {item.text}
                </span>
              </li>
            )
          })}
        </ul>
      )}

      {insight.questions.length > 0 && (
        <div className="space-y-1.5 border-t pt-3">
          <p className="flex items-center gap-1.5 font-mono text-[0.68rem] uppercase tracking-[0.12em] text-muted-foreground">
            <CircleHelp className="size-3" aria-hidden />
            可以追問
          </p>
          <ul className="space-y-1.5">
            {insight.questions.map((q, i) => (
              <li key={i} className="text-sm leading-relaxed">
                {q}
              </li>
            ))}
          </ul>
        </div>
      )}

      <p className="font-mono text-[0.68rem] text-muted-foreground/70">
        {(insight.latencyMs / 1000).toFixed(1)} 秒
      </p>
    </article>
  )
}

export function InsightPanel({
  insights,
  analysing,
  quietRounds,
  health,
  scenarioLabel,
}: {
  insights: Insight[]
  analysing: boolean
  quietRounds: number
  health: Health
  scenarioLabel: string
}) {
  return (
    <div className="flex h-full flex-col gap-3 overflow-y-auto p-4">
      <div className="flex items-center justify-between">
        <h2 className="font-mono text-xs uppercase tracking-[0.14em] text-muted-foreground">
          即時分析 · {scenarioLabel}
        </h2>
        {analysing && (
          <span className="flex items-center gap-1.5 text-xs text-muted-foreground">
            <Loader2 className="size-3 animate-spin" aria-hidden />
            分析中
          </span>
        )}
      </div>

      {insights.length === 0 && !analysing && (
        <p className="rounded-lg border border-dashed p-4 text-sm text-muted-foreground">
          累積一段對話之後會自動分析。太短的內容分析不出東西，所以不會每句話都跑。
        </p>
      )}

      {insights.map((i) => (
        <Card key={i.id} insight={i} />
      ))}

      {quietRounds > 0 && (
        // 「跑了但沒有新東西」也要看得見，否則跟「沒在跑」長得一樣
        <p className="text-xs text-muted-foreground">
          另有 {quietRounds} 輪分析沒有新內容可補（重複的不會再列一次）
        </p>
      )}

      {health.insightErrors.length > 0 && (
        <div className="space-y-2">
          {health.insightErrors.slice(-2).map((e, i) => (
            <div
              key={`${e.code}-${i}`}
              className="flex gap-2 rounded-lg border border-amber-500/40 bg-amber-500/5 p-3"
            >
              <AlertTriangle
                className="mt-0.5 size-3.5 shrink-0 text-amber-600 dark:text-amber-400"
                aria-hidden
              />
              <p className="text-xs">
                分析失敗（{e.code}）：{e.message}
              </p>
            </div>
          ))}
        </div>
      )}
    </div>
  )
}
