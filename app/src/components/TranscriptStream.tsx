import { useEffect, useMemo, useRef } from "react"
import { formatClock, groupSegments } from "@/lib/protocol"
import type { Segment } from "@/lib/useMeetingSocket"

export function TranscriptStream({
  segments,
  partial,
  warming,
}: {
  segments: Segment[]
  partial: string
  warming: boolean
}) {
  const endRef = useRef<HTMLDivElement>(null)
  const wrapRef = useRef<HTMLDivElement>(null)
  const pinnedRef = useRef(true)
  // 一個 final 是一秒 chunk 的增量，直接畫就是一行一秒。合併成段落再畫。
  const paragraphs = useMemo(() => groupSegments(segments), [segments])

  // 使用者往上捲去看前面時，不要把他拉回底部
  useEffect(() => {
    const el = wrapRef.current
    if (!el) return
    const onScroll = () => {
      pinnedRef.current = el.scrollHeight - el.scrollTop - el.clientHeight < 80
    }
    el.addEventListener("scroll", onScroll, { passive: true })
    return () => el.removeEventListener("scroll", onScroll)
  }, [])

  useEffect(() => {
    if (pinnedRef.current) endRef.current?.scrollIntoView({ block: "end" })
  }, [segments.length, partial])

  if (warming) {
    return (
      <div className="flex h-full items-center justify-center p-8">
        <div className="max-w-sm space-y-3 text-center">
          <div
            className="mx-auto h-1 w-32 overflow-hidden rounded-full bg-muted"
            role="progressbar"
            aria-label="模型預熱中"
          >
            <div className="h-full w-1/3 animate-pulse rounded-full bg-primary" />
          </div>
          <p className="text-sm font-medium">正在預熱模型</p>
          <p className="text-sm text-muted-foreground">
            第一次推論要編譯 GPU kernel，約 45 秒。預熱完才開始收音，
            所以你不會漏掉開場。
          </p>
        </div>
      </div>
    )
  }

  return (
    <div ref={wrapRef} className="h-full overflow-y-auto px-6 py-6">
      <div className="mx-auto flex max-w-3xl flex-col gap-4">
        {segments.length === 0 && !partial && (
          <p className="py-16 text-center text-sm text-muted-foreground">
            在聽了。開始講話就會出現逐字稿。
          </p>
        )}

        {paragraphs.map((s) => (
          <article key={s.id} className="grid grid-cols-[3.5rem_1fr] gap-4">
            <time className="pt-0.5 font-mono text-xs tabular-nums text-muted-foreground">
              {formatClock(s.startMs)}
            </time>
            <p className="text-[0.975rem] leading-relaxed">{s.text}</p>
          </article>
        ))}

        {partial && (
          <article className="grid grid-cols-[3.5rem_1fr] gap-4">
            <span className="pt-0.5 font-mono text-xs text-muted-foreground/60">···</span>
            <p className="text-[0.975rem] leading-relaxed text-muted-foreground">
              {partial}
            </p>
          </article>
        )}
        <div ref={endRef} />
      </div>
    </div>
  )
}
