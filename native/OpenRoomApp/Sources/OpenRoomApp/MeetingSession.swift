import Foundation

enum Phase { case idle, connecting, warming, live, stopped, failed }

/// Swift 端的 `useMeetingSocket` + `useAudioCapture` + `App.tsx` 裡 start/stop 那段
/// 邏輯，合成一個 ObservableObject。跟 web 版共用同一份 docs/protocol.md。
@MainActor
final class MeetingSession: ObservableObject {
    @Published var phase: Phase = .idle
    @Published var segments: [Segment] = []
    @Published var partial: String = ""
    @Published var health = Health()
    @Published var engine: String? = nil
    @Published var warmupSec: Double? = nil
    @Published var audioMs: Int = 0
    @Published var insights: [Insight] = []
    @Published var turns: [SpeakerTurn] = []
    @Published var speakers: Int = 0
    @Published var analysing = false
    @Published var quietRounds = 0
    @Published var lastError: String? = nil

    let capture = AudioCapture()
    private var ws: URLSessionWebSocketTask?
    private var seq: UInt32 = 0
    private var ready = false
    private var pending: [Data] = []

    func start(host: String, port: Int, source: AudioSource, scenario: Scenario) async {
        segments = []; partial = ""; health = Health(); insights = []
        turns = []; speakers = 0; quietRounds = 0; audioMs = 0
        seq = 0; ready = false; pending = []
        phase = .connecting

        guard let url = URL(string: "ws://\(host):\(port)/ws/m\(Int(Date().timeIntervalSince1970 * 1000))") else {
            phase = .failed; return
        }
        let task = URLSession(configuration: .default).webSocketTask(with: url)
        ws = task
        task.resume()
        receiveLoop(task)

        phase = .warming
        sendJSON([
            "type": "start", "sample_rate": SAMPLE_RATE, "channels": 1,
            "format": "s16le", "source": source.rawValue, "scenario": scenario.rawValue,
            "engine": "qwen-mlx",
        ])

        capture.onFrame = { [weak self] pcm in
            Task { @MainActor in self?.sendAudio(pcm) }
        }
        let capturing = await capture.start(source: source)
        if !capturing {
            lastError = capture.lastError
            stop()
        }
    }

    func stop() {
        capture.stop()
        if let ws, ws.state == .running { sendJSON(["type": "stop"]) }
    }

    /// 匯出跟畫面看到的一樣是段落，不是一行一秒的碎片。
    func exportMarkdown() -> String {
        let names = speakerNames(turns)
        let body = groupSegments(segments, turns: turns).map { s -> String in
            let clock = formatClock(s.startMs)
            // 有講者名字時冒號的樣子各語言不同（en ": " / zh、ja "："），所以整行都是一個 key。
            guard let who = s.speaker.flatMap({ names[$0] }) else {
                return String(format: L("[%1$@] %2$@"), clock, s.text)
            }
            return String(format: L("[%1$@] %2$@: %3$@"), clock, who, s.text)
        }.joined(separator: "\n\n")
        return "\(L("# Meeting Transcript"))\n\n\(body)\n"
    }

    // MARK: - send

    private func sendAudio(_ pcm: Data) {
        guard let ws, ws.state == .running else {
            health.droppedBeforeReady += 1
            return
        }
        if !ready {
            if pending.count >= 600 { health.droppedBeforeReady += 1; return } // 60s 上限，跟 TS 版一致
            pending.append(pcm)
            return
        }
        let s = seq; seq += 1
        ws.send(.data(frameWithHeader(seq: s, audioTsMs: s * UInt32(CHUNK_MS), pcm: pcm))) { _ in }
    }

    private func flushPending() {
        guard let ws else { return }
        for pcm in pending {
            let s = seq; seq += 1
            ws.send(.data(frameWithHeader(seq: s, audioTsMs: s * UInt32(CHUNK_MS), pcm: pcm))) { _ in }
        }
        pending = []
    }

    private func sendJSON(_ obj: [String: Any]) {
        guard let ws, let data = try? JSONSerialization.data(withJSONObject: obj),
              let text = String(data: data, encoding: .utf8) else { return }
        ws.send(.string(text)) { _ in }
    }

    // MARK: - receive

    private nonisolated func receiveLoop(_ task: URLSessionWebSocketTask) {
        task.receive { result in
            switch result {
            case .failure(let error):
                // 舊版在這裡（TS 版 ws.onerror/onclose）都會明講並讓 UI 回設定畫面；
                // 這支一度漏掉這段，斷線後 UI 會靜靜卡在「預熱中」——正是這專案第一守則
                // 禁止的那種靜默降級。done/stop 是正常收工路徑，走 stop()，不會走到這裡。
                Task { @MainActor [weak self] in
                    guard let self, self.phase != .stopped else { return }
                    self.health.errors.append(HealthError(
                        code: "ws_error",
                        message: String(format: L("Connection closed: %@. Is the backend running?"),
                                        error.localizedDescription),
                        fatal: true))
                    self.phase = .failed
                }
                return
            case .success(let msg):
                if case .string(let text) = msg,
                   let data = text.data(using: .utf8),
                   let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                    Task { @MainActor [weak self] in self?.handle(obj) }
                }
                self.receiveLoop(task)
            }
        }
    }

    private func handle(_ ev: [String: Any]) {
        guard let type = ev["type"] as? String else { return }
        func s(_ k: String) -> String { ev[k] as? String ?? "" }
        func i(_ k: String) -> Int { (ev[k] as? NSNumber)?.intValue ?? 0 }
        func d(_ k: String) -> Double? { (ev[k] as? NSNumber)?.doubleValue }

        switch type {
        case "ready":
            ready = true
            flushPending()
            engine = ev["engine"] as? String
            warmupSec = d("warmup_sec")
            phase = .live
        case "final":
            segments.append(Segment(id: "\(i("start_ms"))-\(segments.count)", text: s("text"),
                                     speaker: s("speaker"), startMs: i("start_ms"), endMs: i("end_ms")))
            partial = ""
            audioMs = i("end_ms")
            if let infer = d("infer_ms") { health.lastInferMs = infer }
        case "partial":
            partial = s("text")
            audioMs = i("end_ms")
            if let infer = d("infer_ms") { health.lastInferMs = infer }
        case "revise":
            health.revisions += 1
        case "no_speech":
            audioMs = i("end_ms")
            health.noSpeech += 1
        case "gap":
            health.gaps += 1
            health.lostMs += i("lost_ms")
            if s("reason") == "asr_backpressure" { health.backpressure += 1 }
        case "error":
            let fatal = (ev["fatal"] as? Bool) ?? false
            health.errors.append(HealthError(code: s("code"), message: s("message"), fatal: fatal))
            if fatal { phase = .failed }
        case "insight_pending":
            analysing = true
        case "insight":
            let items = (ev["items"] as? [[String: Any]] ?? []).map {
                InsightItem(kind: $0["kind"] as? String ?? "", text: $0["text"] as? String ?? "")
            }
            let questions = ev["questions"] as? [String] ?? []
            insights.insert(Insight(headline: s("headline"), items: items, questions: questions,
                                     atMs: i("at_ms"), latencyMs: i("latency_ms")), at: 0)
            analysing = false
        case "insight_none":
            analysing = false
            quietRounds += 1
        case "insight_error":
            analysing = false
            health.insightErrors.append((code: s("code"), message: s("message")))
        case "speaker_turns":
            turns = (ev["turns"] as? [[String: Any]] ?? []).map {
                SpeakerTurn(speaker: $0["speaker"] as? String ?? "",
                            startMs: ($0["start_ms"] as? NSNumber)?.intValue ?? 0,
                            endMs: ($0["end_ms"] as? NSNumber)?.intValue ?? 0)
            }
            speakers = i("speakers")
        case "speaker_error":
            health.speakerErrors.append((code: s("code"), message: s("message")))
        case "done":
            phase = .stopped
            analysing = false
        default:
            break
        }
    }
}
