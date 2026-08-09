// node src/lib/i18n.check.ts —— 只驗語系判定與 {var} 代換。
// key 有沒有漏、有沒有打錯，TypeScript 已經擋住了，這裡不重複。
import assert from "node:assert/strict"

// i18n.ts 一載入就讀瀏覽器全域，先擺上最小替身
const store = new Map<string, string>()
const define = (name: string, value: unknown) =>
  Object.defineProperty(globalThis, name, { value, configurable: true, writable: true })

define("localStorage", {
  getItem: (k: string) => store.get(k) ?? null,
  setItem: (k: string, v: string) => void store.set(k, v),
})
// 第一個認得的才算數：fr 不支援要跳過，不是整串放棄改用英文
define("navigator", { languages: ["fr-FR", "zh-HK", "en-US"] })
define("document", { documentElement: { lang: "" } })

const { t, setLocale, getLocale } = await import("./i18n.ts")

assert.equal(getLocale(), "zh-Hant") // zh-HK 是繁體
assert.equal(document.documentElement.lang, "zh-Hant")

assert.equal(t("speaker.n", { n: 3 }), "講者 3")
assert.ok(t("speaker.n").includes("{n}")) // 沒帶值就原樣留著，破字看得見好過默默吞掉

setLocale("en")
assert.equal(t("speaker.n", { n: 3 }), "Speaker 3")
assert.equal(document.documentElement.lang, "en") // <html lang> 要跟著換
assert.equal(store.get("openroom.locale"), "en") // 選擇要留得住

console.log("i18n check ok")
