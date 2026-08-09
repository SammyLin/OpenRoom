import FluidAudio
import Foundation

// 解決「幾乎每次都噴 speaker_error/hf_token_missing」：pyannote 是 gated repo，要 HF_TOKEN。
// FluidAudio（github.com/FluidInference/FluidAudio）把同一套模型轉成 CoreML，放在
// 公開、不用登入的 FluidInference/speaker-diarization-coreml，換掉這顆就不用管 token。
//
// 這支只做一件事：吃一個音檔路徑，跑完整段 diarization，把講者時間軸印成 JSON 到
// stdout。跟 openroom/diarize_worker.py 的 speaker_turns.turns[] 同一個形狀
// （speaker/start_ms/end_ms），Python 端 subprocess 呼叫、parse stdout 就能接上，
// 不用改協定。

struct SpeakerTurn: Encodable {
    let speaker: String
    let start_ms: Int
    let end_ms: Int
}

func eprint(_ s: String) {
    FileHandle.standardError.write((s + "\n").data(using: .utf8)!)
}

/// .pcm/.raw 沒有容器可以讓 AVAudioFile 讀，協定本來就規定 16kHz mono s16le，
/// 直接手動轉 Float，不用再繞 AVAudioConverter。
func loadRawPCM(path: String) throws -> [Float] {
    let data = try Data(contentsOf: URL(fileURLWithPath: path))
    guard data.count >= 2 else { return [] }
    var samples = [Float](repeating: 0, count: data.count / 2)
    data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
        for i in 0..<samples.count {
            let lo = UInt16(raw[i * 2])
            let hi = UInt16(raw[i * 2 + 1])
            let s16 = Int16(bitPattern: lo | (hi << 8))
            samples[i] = Float(s16) / 32768.0
        }
    }
    return samples
}

/// loadRawPCM 的 s16le 小端解碼——不用模型也不用真的檔案，跑純邏輯。
func selfcheck() {
    let tmp = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("openroom-diarize-selfcheck.pcm")
    // Int16 值：0, 32767 (max), -32768 (min)，都用小端寫入
    let bytes: [UInt8] = [0x00, 0x00, 0xFF, 0x7F, 0x00, 0x80]
    try! Data(bytes).write(to: tmp)
    defer { try? FileManager.default.removeItem(at: tmp) }

    let got = try! loadRawPCM(path: tmp.path)
    assert(got.count == 3, "expected 3 samples, got \(got.count)")
    assert(abs(got[0] - 0.0) < 1e-6, "0 -> \(got[0])")
    assert(abs(got[1] - 0.999969482) < 1e-6, "32767 -> \(got[1])")
    assert(abs(got[2] - (-1.0)) < 1e-6, "-32768 -> \(got[2])")
    print("selfcheck ok")
}

let args = CommandLine.arguments
if args.count == 2, args[1] == "--selfcheck" {
    selfcheck()
    exit(0)
}
guard args.count == 2, args[1] != "--help" else {
    eprint(
        """
        usage: openroom-diarize <audio-file>
          有容器的檔案（.wav/.aiff/…）：直接讀，AVAudioFile 自己處理格式/重採樣。
          .pcm/.raw：當作無 header 的 16kHz mono s16le 原始 PCM。
        """)
    exit(args.count == 2 ? 0 : 2)
}

let path = args[1]
let ext = (path as NSString).pathExtension.lowercased()

func loadSamples(path: String, ext: String) throws -> [Float] {
    if ext == "pcm" || ext == "raw" {
        return try loadRawPCM(path: path)
    }
    return try AudioConverter().resampleAudioFile(path: path)
}

do {
    let samples = try loadSamples(path: path, ext: ext)
    guard !samples.isEmpty else {
        eprint("❌ 沒讀到音訊: \(path)")
        exit(1)
    }
    eprint("載入 \(samples.count) samples（\(String(format: "%.1f", Double(samples.count) / 16000.0))s）…")

    let manager = DiarizerManager(config: .default)
    eprint("載入模型中…（第一次跑會從 HuggingFace 下載 FluidInference/speaker-diarization-coreml，公開 repo，不用 HF_TOKEN）")
    let models = try await DiarizerModels.downloadIfNeeded()
    manager.initialize(models: models)

    let result = try manager.performCompleteDiarization(samples, sampleRate: 16000)
    let turns =
        result.segments
        .map {
            SpeakerTurn(
                speaker: $0.speakerId,
                start_ms: Int(($0.startTimeSeconds * 1000).rounded()),
                end_ms: Int(($0.endTimeSeconds * 1000).rounded()))
        }
        .sorted { $0.start_ms < $1.start_ms }

    let encoder = JSONEncoder()
    let jsonData = try encoder.encode(turns)
    print(String(data: jsonData, encoding: .utf8)!)
} catch {
    eprint("❌ diarization 失敗: \(error)")
    exit(1)
}
