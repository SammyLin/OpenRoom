import Foundation
import MLXAudioSTT

/// Qwen3-ASR 串流轉錄，取代 `openroom/asr_worker.py`。
///
/// 事件格式刻意跟 `docs/protocol.md` 一模一樣（`ready` / `partial` / `final` /
/// `no_speech` / `error` / `done`），這樣 `MeetingSession.handle` 跟 `events.jsonl`
/// 都不用改——換掉的只有傳輸方式，不是協定。
///
/// Python 版有 80 行在補套件的合併邏輯（標點不同就找不到重疊，逐字稿變成「在三月。
/// 月中的。時候」）。`StreamingInferenceSession` 自己做 confirmed/provisional 升級，
/// 那段整個不用移植，`revise` 事件也隨之消失——文字只會往前長，不會回頭改寫。
final class ASREngine {
    static let sampleRate = 16_000

    /// 事件出口。跟 Python 的 `out_q` 對應，只是這裡不用跨 process。
    private let emit: @Sendable ([String: Any]) -> Void
    private var session: StreamingInferenceSession?
    private var pump: Task<Void, Never>?

    /// 已經餵進模型的音訊位置，`start_ms` / `end_ms` 都從這裡算。
    private var audioMs = 0
    private var confirmed = ""
    private var lastProvisional = ""
    private var stableEndMs = 0

    init(emit: @escaping @Sendable ([String: Any]) -> Void) {
        self.emit = emit
    }

    /// 載入模型並開始收音。冷啟動要編 Metal kernel，所以 `ready` 一定等到載完才發——
    /// 提早說 ready 等於叫上層把開場白送進黑洞。
    func start(model repo: String, language: String?, context: String) async {
        let t0 = Date()
        let loaded: any STTGenerationModel
        do {
            loaded = try await STT.loadModel(modelRepo: repo)
        } catch {
            // 載入失敗要吵，不能降級成假資料
            emit(["type": "error", "code": "model_load_failed",
                  "message": "\(error)", "fatal": true])
            return
        }

        var cfg = StreamingConfig()
        // nil = 讓模型自己判斷，中英夾雜需要。Python 那邊 `--language` 不給就是這個行為。
        cfg.language = language
        // agent（480ms）是延遲與修正次數的折衷。realtime 會讓 provisional 一直跳動，
        // subtitle 的 2.4 秒過不了 docs/measurements.md 的 partial gate。
        cfg.delayPreset = .agent

        let session = StreamingInferenceSession(model: loaded, config: cfg)
        self.session = session
        pump = Task { [weak self] in
            for await event in session.events {
                await self?.handle(event)
            }
        }

        emit(["type": "ready", "engine": "qwen-mlx-swift", "model": repo,
              "sample_rate": Self.sampleRate,
              "warmup_sec": (Date().timeIntervalSince(t0) * 10).rounded() / 10])
    }

    /// 收音永遠不等推論：塞進去就結束。背壓由 session 內部處理。
    func feed(_ samples: [Float]) {
        guard let session else { return }
        audioMs += samples.count * 1000 / Self.sampleRate
        session.feedAudio(samples: samples)
    }

    func stop() {
        session?.stop()
    }

    // MARK: - 事件轉換

    @MainActor
    private func handle(_ event: TranscriptionEvent) {
        switch event {
        case .displayUpdate(let confirmedText, let provisionalText):
            emitConfirmedDelta(confirmedText)
            let tail = Self.toTraditional(provisionalText).trimmed
            if !tail.isEmpty, tail != lastProvisional {
                lastProvisional = tail
                emit(["type": "partial", "text": tail, "speaker": "spk_1",
                      "start_ms": stableEndMs, "end_ms": audioMs])
            }

        case .confirmed(let text):
            emitConfirmedDelta(text)

        case .provisional:
            break  // displayUpdate 已經涵蓋，重複發只會讓 UI 抖

        case .stats(let s):
            // RTF > 1 就是死亡螺旋的前兆，靜靜跑下去等於舊版那種查不出原因的落後
            if s.realTimeFactor > 1.0 {
                emit(["type": "gap", "expected_seq": 0, "got_seq": 0, "lost_ms": 0,
                      "reason": "asr_backpressure"])
            }

        case .ended(let fullText):
            emit(["type": "done", "audio_ms": audioMs,
                  "text": Self.toTraditional(fullText).trimmed])
        }
    }

    /// confirmed 是「到目前為止的全文」，UI 要的是增量。
    private func emitConfirmedDelta(_ full: String) {
        let converted = Self.toTraditional(full)
        guard converted.count > confirmed.count,
              converted.hasPrefix(confirmed) else {
            confirmed = converted
            return
        }
        let delta = String(converted.dropFirst(confirmed.count)).trimmed
        confirmed = converted
        guard !delta.isEmpty else { return }
        lastProvisional = ""
        emit(["type": "final", "text": delta, "speaker": "spk_1",
              "start_ms": stableEndMs, "end_ms": audioMs])
        stableEndMs = audioMs
    }

    /// Qwen3-ASR 中文一律吐簡體，使用者是台灣人。ICU 的 Hans-Hant transliterator 就夠，
    /// 不用為了這件事引入一個字典套件。英文是 no-op。
    static func toTraditional(_ text: String) -> String {
        guard !text.isEmpty else { return text }
        let mutable = NSMutableString(string: text) as CFMutableString
        guard CFStringTransform(mutable, nil, "Hans-Hant" as CFString, false) else { return text }
        return mutable as String
    }
}

private extension String {
    var trimmed: String { trimmingCharacters(in: .whitespacesAndNewlines) }
}
