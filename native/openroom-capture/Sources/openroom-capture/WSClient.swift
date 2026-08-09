import Foundation

/// Client 端實作 docs/protocol.md：送 8-byte header + s16le PCM，收 JSON 事件。
/// 沒有 reconnect、沒有 ring buffer——跟 Python server 同一個哲學：單機 localhost，
/// 為不存在的問題（斷線重連）付錢是不必要的複雜度。
final class OpenRoomClient: NSObject {
    private let task: URLSessionWebSocketTask
    private var seq: UInt32 = 0
    private(set) var readyReceived = false
    private(set) var doneReceived = false
    var verbose = false

    init(url: URL) {
        task = URLSession(configuration: .default).webSocketTask(with: url)
        super.init()
        task.resume()
        receiveLoop()
    }

    func sendStart(scenario: String) {
        send(json: [
            "type": "start", "sample_rate": 16000, "channels": 1,
            "format": "s16le", "source": "system", "scenario": scenario,
            "engine": "qwen-mlx",
        ])
    }

    func sendStop() {
        send(json: ["type": "stop"])
    }

    /// pcm 必須恰好 3200 bytes（100 ms @ 16kHz s16le mono）——協定要求固定長度。
    func sendFrame(pcm: Data, tsMs: UInt32) {
        var header = Data(capacity: 8)
        var seqBE = seq.bigEndian
        var tsBE = tsMs.bigEndian
        withUnsafeBytes(of: &seqBE) { header.append(contentsOf: $0) }
        withUnsafeBytes(of: &tsBE) { header.append(contentsOf: $0) }
        seq += 1
        task.send(.data(header + pcm)) { err in
            if let err = err { eprint("frame 送出失敗: \(err)") }
        }
    }

    private func send(json: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: json),
              let text = String(data: data, encoding: .utf8) else { return }
        task.send(.string(text)) { err in
            if let err = err { eprint("送出失敗: \(err)") }
        }
    }

    private func receiveLoop() {
        task.receive { [weak self] result in
            guard let self else { return }
            switch result {
            case .failure(let err):
                print("[ws] 連線結束: \(err)")
                return
            case .success(let msg):
                if case .string(let text) = msg { self.handle(text) }
                self.receiveLoop()
            }
        }
    }

    private func handle(_ text: String) {
        guard let data = text.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = obj["type"] as? String else { return }
        switch type {
        case "ready":
            readyReceived = true
            print("[ws] ready engine=\(obj["engine"] ?? "?")")
        case "partial":
            if verbose { print("… \(obj["text"] ?? "")") }
        case "final":
            print("[final] \(obj["text"] ?? "")")
        case "no_speech":
            break
        case "gap":
            print("⚠️  gap: \(obj)")
        case "revise":
            print("[revise] \(obj)")
        case "error":
            print("❌ error: \(obj)")
        case "insight_pending":
            print("[insight] 分析中…")
        case "insight":
            print("💡 \(obj["headline"] ?? "")")
        case "insight_error":
            print("⚠️  insight_error: \(obj)")
        case "speaker_ready":
            print("[speaker] 模型載好了")
        case "speaker_turns":
            print("[speaker] turns=\((obj["turns"] as? [Any])?.count ?? 0) speakers=\(obj["speakers"] ?? "?")")
        case "speaker_error":
            print("⚠️  speaker_error: \(obj)")
        case "done":
            doneReceived = true
            print("[ws] done text_len=\((obj["text"] as? String)?.count ?? 0)")
        default:
            break
        }
    }
}

func eprint(_ s: String) {
    FileHandle.standardError.write((s + "\n").data(using: .utf8)!)
}
