// 把 AudioWorklet 的 float32 轉成 s16le，每 1600 個 sample（100 ms @ 16 kHz）送一包。
//
// 這裡**沒有**降採樣。AudioContext 直接開在 16 kHz，讓瀏覽器自己做正規的重採樣。
// 舊版在 worklet 裡自己用 box-average 抽樣（pcm-worklet.js:27-37），沒有抗混疊濾波，
// 48 kHz → 16 kHz 會把 8 kHz 以上的能量摺回語音頻段。

const FRAME = 1600 // 100 ms @ 16 kHz，對齊 docs/protocol.md

class PCMWorklet extends AudioWorkletProcessor {
  constructor() {
    super()
    this.buf = new Int16Array(FRAME)
    this.n = 0
  }

  process(inputs) {
    const ch = inputs[0]?.[0]
    if (!ch) return true
    for (let i = 0; i < ch.length; i++) {
      const s = Math.max(-1, Math.min(1, ch[i]))
      this.buf[this.n++] = s < 0 ? s * 0x8000 : s * 0x7fff
      if (this.n === FRAME) {
        const out = this.buf.slice()
        this.port.postMessage(out.buffer, [out.buffer])
        this.n = 0
      }
    }
    return true
  }
}

registerProcessor("pcm-worklet", PCMWorklet)
