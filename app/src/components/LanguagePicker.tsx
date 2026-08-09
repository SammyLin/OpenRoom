import { Languages } from "lucide-react"
import { LOCALES, LOCALE_NAMES, setLocale, t, useLocale, type Locale } from "@/lib/i18n"
import { cn } from "@/lib/utils"

/**
 * 原生 <select>：四個選項不值得為它裝一套 menu 元件，鍵盤操作與無障礙也是白拿的。
 * 樣式對齊 Button 的 ghost/sm，讓它在兩個 header 裡都不突兀。
 */
export function LanguagePicker({ className }: { className?: string }) {
  const locale = useLocale() // 訂閱換語言，同時拿到目前值

  return (
    <div className={cn("relative inline-flex items-center", className)}>
      <Languages
        className="pointer-events-none absolute left-2 size-3.5 text-muted-foreground"
        aria-hidden
      />
      <select
        aria-label={t("lang.label")}
        value={locale}
        onChange={(e) => setLocale(e.target.value as Locale)}
        className="h-7 cursor-pointer appearance-none rounded-lg border border-transparent bg-transparent py-0 pl-7 pr-2 text-[0.8rem] font-medium text-muted-foreground outline-none transition-colors hover:bg-muted hover:text-foreground focus-visible:border-ring focus-visible:ring-3 focus-visible:ring-ring/50"
      >
        {LOCALES.map((l) => (
          <option key={l} value={l} className="bg-background text-foreground">
            {LOCALE_NAMES[l]}
          </option>
        ))}
      </select>
    </div>
  )
}
