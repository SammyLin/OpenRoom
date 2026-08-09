// node src/lib/protocol.check.ts —— Node 直接跑 TS，不為了四個斷言裝測試框架。
import assert from "node:assert/strict"
import { groupSegments, speakerAt, speakerIndex } from "./protocol.ts"

const seg = (text: string, startMs: number, endMs: number) => ({ text, startMs, endMs })

// 一秒一段的碎片要合成一段
const merged = groupSegments([
  seg("my", 0, 1000),
  seg("name is Andrew", 1000, 2000),
  seg("Cummins I'm a", 2000, 3000),
])
assert.equal(merged.length, 1)
assert.equal(merged[0].text, "my name is Andrew Cummins I'm a")
assert.equal(merged[0].endMs, 3000)

// 夠長又結在句尾才換段
const twoParas = groupSegments([
  seg("hello there.", 0, 7000),
  seg("second thing", 7000, 8000),
])
assert.equal(twoParas.length, 2)

// 沒到 PARA_MIN_MS 的句號不換段，否則又變成一行一句
assert.equal(groupSegments([seg("design.", 0, 1000), seg("designer on", 1000, 2000)]).length, 1)

// 中文不加空白；英文「句號 + 小寫」是模型亂斷的，接起來要拿掉
assert.equal(
  groupSegments([seg("在三月中。", 0, 1000), seg("的時候", 1000, 2000)])[0].text,
  "在三月中。的時候",
)
assert.equal(
  groupSegments([seg("product design.", 0, 1000), seg("designer on", 1000, 2000)])[0].text,
  "product design designer on",
)

// 硬上限：一直沒有句號也要換段
const long = Array.from({ length: 30 }, (_, i) => seg(`w${i}`, i * 1000, (i + 1) * 1000))
assert.ok(groupSegments(long).length >= 2)

console.log("protocol check ok")

// 講者：重疊最多的那個 turn 說了算，換人就換段
const turns = [
  { speaker: "SPEAKER_01", start_ms: 0, end_ms: 5000 },
  { speaker: "SPEAKER_00", start_ms: 5000, end_ms: 9000 },
]
const withSpk = groupSegments(
  [seg("hello there", 0, 2000), seg("still me", 2000, 4000), seg("now me", 5000, 8000)],
  turns,
)
assert.equal(withSpk.length, 2)                       // 換人就換段，不看句號
assert.equal(withSpk[0].text, "hello there still me")
assert.equal(withSpk[1].speaker, "SPEAKER_00")
assert.equal(speakerIndex(turns).get("SPEAKER_01"), 1)  // 依第一次出現排序
assert.equal(speakerIndex(turns).get("SPEAKER_00"), 2)
assert.equal(speakerAt(turns, 9000, 9500), null)      // 沒涵蓋到就不亂猜

console.log("speaker check ok")
