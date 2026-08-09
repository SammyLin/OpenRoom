import Foundation
import SwiftUI

// Swift 端的 docs/protocol.md，跟 app/src/lib/protocol.ts 是同一份規格的兩個實作。
// 改這裡要記得改文件（跟 TS 那份的警語一樣）。

let SAMPLE_RATE = 16_000
let CHUNK_MS = 100
let CHUNK_SAMPLES = SAMPLE_RATE * CHUNK_MS / 1000 // 1600
let FRAME_BYTES = CHUNK_SAMPLES * 2 // s16le

enum AudioSource: String, CaseIterable {
    case system, mic
}

enum Scenario: String, CaseIterable {
    case discussion, interview

    var label: String {
        switch self {
        case .discussion: return "討論會議"
        case .interview: return "面試"
        }
    }

    var detail: String {
        switch self {
        case .discussion: return "補上被提到的工具、名詞、數字的背景資料，標出值得查證的說法。"
        case .interview: return "判斷受訪者的答案是否正確、哪裡含糊，並建議接下來該追問什麼。"
        }
    }

    var icon: String {
        switch self {
        case .discussion: return "person.3.fill"
        case .interview: return "person.fill.questionmark"
        }
    }
}

extension AudioSource {
    var icon: String {
        switch self {
        case .system: return "display"
        case .mic: return "mic.fill"
        }
    }
}

/// 講者頭像顏色：同名字每次都拿到同一色，跟系統色板走（深色模式自動跟著換）。
private let speakerPalette: [Color] = [.blue, .purple, .orange, .teal, .pink, .indigo, .green, .brown]
func speakerColor(_ name: String) -> Color {
    var hash = 0
    for u in name.unicodeScalars { hash = 31 &* hash &+ Int(u.value) }
    return speakerPalette[abs(hash) % speakerPalette.count]
}

struct InsightItem: Identifiable {
    let id = UUID()
    let kind: String
    let text: String
}

struct Insight: Identifiable {
    let id = UUID()
    let headline: String
    let items: [InsightItem]
    let questions: [String]
    let atMs: Int
    let latencyMs: Int
}

struct Segment: Identifiable {
    let id: String
    var text: String
    var speaker: String?
    var startMs: Int
    var endMs: Int
}

struct SpeakerTurn {
    let speaker: String
    let startMs: Int
    let endMs: Int
}

struct HealthError: Identifiable {
    let id = UUID()
    let code: String
    let message: String
    let fatal: Bool
}

struct Health {
    var noSpeech = 0
    var gaps = 0
    var lostMs = 0
    var backpressure = 0
    var revisions = 0
    var errors: [HealthError] = []
    var lastInferMs: Double? = nil
    var droppedBeforeReady = 0
    var insightErrors: [(code: String, message: String)] = []
    var speakerErrors: [(code: String, message: String)] = []

    var clean: Bool { gaps == 0 && errors.isEmpty && droppedBeforeReady == 0 }
}

/// 8 byte header: seq (uint32 BE) + audio_ts_ms (uint32 BE) + PCM。
func frameWithHeader(seq: UInt32, audioTsMs: UInt32, pcm: Data) -> Data {
    var out = Data(capacity: 8 + pcm.count)
    var seqBE = seq.bigEndian
    var tsBE = audioTsMs.bigEndian
    withUnsafeBytes(of: &seqBE) { out.append(contentsOf: $0) }
    withUnsafeBytes(of: &tsBE) { out.append(contentsOf: $0) }
    out.append(pcm)
    return out
}

// MARK: - 段落分組（protocol.ts groupSegments 的 port）

private let PARA_MIN_MS = 6_000
private let PARA_MAX_MS = 20_000

private func isSentenceEnd(_ s: String) -> Bool {
    guard let last = s.trimmingCharacters(in: .whitespaces).unicodeScalars.last else { return false }
    return ".。!！?？".unicodeScalars.contains(last)
}

private func isCJK(_ s: String) -> Bool {
    s.unicodeScalars.contains { $0.value >= 0x4E00 && $0.value <= 0x9FFF }
}

private func joinText(_ left: String, _ right: String) -> String {
    if isCJK(left) || isCJK(right) { return left + right }
    let startsLower = right.first.map { $0.isLowercase } ?? false
    let trimmed = startsLower && left.hasSuffix(".") ? String(left.dropLast()) : left
    return "\(trimmed) \(right)"
}

/// 誰講的：跟哪個 turn 重疊最多就算誰的。
func speakerAt(_ turns: [SpeakerTurn], startMs: Int, endMs: Int) -> String? {
    var best: String? = nil
    var bestOverlap = 0
    for t in turns {
        let overlap = min(endMs, t.endMs) - max(startMs, t.startMs)
        if overlap > bestOverlap { bestOverlap = overlap; best = t.speaker }
    }
    return best
}

/// SPEAKER_00 對人沒意義：照第一次出現順序改叫「講者 1」。
func speakerNames(_ turns: [SpeakerTurn]) -> [String: String] {
    var m: [String: String] = [:]
    for t in turns where m[t.speaker] == nil { m[t.speaker] = "講者 \(m.count + 1)" }
    return m
}

func groupSegments(_ segments: [Segment], turns: [SpeakerTurn] = []) -> [Segment] {
    var out: [Segment] = []
    for raw in segments {
        var s = raw
        if !turns.isEmpty { s.speaker = speakerAt(turns, startMs: raw.startMs, endMs: raw.endMs) }
        if var last = out.last,
           last.speaker == s.speaker,
           !(last.endMs - last.startMs >= PARA_MAX_MS ||
             (last.endMs - last.startMs >= PARA_MIN_MS && isSentenceEnd(last.text))) {
            last.text = joinText(last.text, s.text)
            last.endMs = s.endMs
            out[out.count - 1] = last
        } else {
            out.append(s)
        }
    }
    return out
}

func formatClock(_ ms: Int) -> String {
    let total = ms / 1000
    let h = total / 3600
    let m = (total % 3600) / 60
    let s = total % 60
    return h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%02d:%02d", m, s)
}
