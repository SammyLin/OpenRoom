import Foundation
import MLX
import MLXAudioVAD

/// 講者分離，取代 `openroom/diarize_worker.py`。
///
/// pyannote 不是串流模型，所以 Python 版只能「對整場音訊重跑」，成本隨會議長度線性上升，
/// 還要用「跑完休息 8 倍時間」的工作週期壓住，免得跟 ASR 搶同一顆 GPU（實測搶起來
/// 單次 ASR 推論從 0.37 秒掉到 54 秒）。代價是講者標籤是**回填**的，會晚很多。
///
/// Sortformer 是串流模型，上面那整套都不需要：固定 chunk 餵進去，講者標籤即時出來，
/// 而且跨 chunk 的講者身分由 `StreamingState` 維持一致。也不用 `HF_TOKEN`——
/// 這不是 gated repo。
///
/// 模型位址在 `ModelStore.diarizer`。之前寫在這裡的 `...4spk-v2` 是個不存在的 repo，
/// 於是這整層每場會議都只吐一個 `speaker_error` 就結束了。
final class Diarizer {
    static let sampleRate = 16_000
    /// 餵給模型的 chunk 長度，跟套件 `generateStream` 的預設一致。
    static let chunkSeconds: Float = 5.0

    private let emit: @Sendable ([String: Any]) -> Void
    private var model: SortformerModel?
    private var state: StreamingState?
    private var buffer: [Float] = []
    /// 已經送進模型的音訊長度（秒）。`feed` 回傳的時間是相對這個 chunk 的，要補回絕對位置。
    private var offsetSeconds: Float = 0
    /// 整場累積的講者段落，每次都整份重發——UI 的 `speaker_turns` 就是「目前為止的全部」。
    private var turns: [[String: Any]] = []
    private var busy = false

    init(emit: @escaping @Sendable ([String: Any]) -> Void) {
        self.emit = emit
    }

    func start(model repo: String = ModelStore.diarizer.repo) async {
        do {
            let loaded = try await SortformerModel.fromPretrained(repo)
            model = loaded
            state = loaded.initStreamingState()
            emit(["type": "speaker_ready", "model": repo])
        } catch {
            // 沒有講者標籤是缺陷，不是可以靜靜跳過的事
            emit(["type": "speaker_error", "code": "model_load_failed", "message": "\(error)"])
        }
    }

    func feed(_ samples: [Float]) {
        guard model != nil else { return }
        buffer.append(contentsOf: samples)
        let step = Int(Self.chunkSeconds * Float(Self.sampleRate))
        guard buffer.count >= step, !busy else { return }

        let chunk = Array(buffer.prefix(step))
        buffer.removeFirst(step)
        busy = true
        Task { [weak self] in
            await self?.process(chunk)
        }
    }

    /// 收工前把剩下不滿一個 chunk 的音訊也跑完，否則最後幾秒沒有講者標籤。
    func finish() async {
        guard model != nil, !buffer.isEmpty else {
            emit(["type": "speaker_done"])
            return
        }
        let tail = buffer
        buffer = []
        await process(tail)
        emit(["type": "speaker_done"])
    }

    private func process(_ chunk: [Float]) async {
        defer { busy = false }
        guard let model, let current = state else { return }
        let t0 = Date()
        do {
            let audio = MLXArray(chunk)
            let (output, next) = try await model.feed(chunk: audio, state: current,
                                                      sampleRate: Self.sampleRate)
            state = next
            append(output.segments, offset: offsetSeconds)
            offsetSeconds += Float(chunk.count) / Float(Self.sampleRate)
            emit(["type": "speaker_turns", "turns": turns,
                  "speakers": Set(turns.compactMap { $0["speaker"] as? String }).count,
                  "covers_ms": Int(offsetSeconds * 1000),
                  "infer_ms": Int(Date().timeIntervalSince(t0) * 1000)])
        } catch {
            // 講者分離掛掉不能拖垮逐字稿：吵一聲，然後繼續收音
            emit(["type": "speaker_error", "code": "diarize_failed", "message": "\(error)"])
            offsetSeconds += Float(chunk.count) / Float(Self.sampleRate)
        }
    }

    /// `_turns` 的移植：0.2 秒以下的碎片是換手瞬間的雜訊，同一人被切開的相鄰段落接回去。
    private func append(_ segments: [DiarizationSegment], offset: Float) {
        for seg in segments.sorted(by: { $0.start < $1.start }) {
            let start = Int((seg.start + offset) * 1000)
            let end = Int((seg.end + offset) * 1000)
            guard end - start >= 200 else { continue }
            let label = String(format: "SPEAKER_%02d", seg.speaker)
            if var last = turns.last, last["speaker"] as? String == label,
               start - (last["end_ms"] as? Int ?? 0) < 400 {
                last["end_ms"] = end
                turns[turns.count - 1] = last
            } else {
                turns.append(["speaker": label, "start_ms": start, "end_ms": end])
            }
        }
    }
}
