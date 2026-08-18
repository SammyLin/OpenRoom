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
    /// 模型下載進度。收音之前一定先過這一關，不然第一次啟動會邊錄音邊抓 1GB，
    /// pending 上限撐不到模型載完，開場白照樣掉。
    let models = ModelStore()
    private var asr: ASREngine?
    private var diarizer: Diarizer?
    private var analyst: Analyst?
    private var log: EventLog?
    private var ready = false
    /// 模型還在載的時候收到的音訊。載完一次補進去，不然開場白會掉。
    private var pending: [[Float]] = []

    func start(source: AudioSource, scenario: Scenario, model: String,
               language: String?, context: String = "") async {
        segments = []; partial = ""; health = Health(); insights = []
        turns = []; speakers = 0; quietRounds = 0; audioMs = 0
        ready = false; pending = []
        phase = .warming

        // 模型沒到位就別開始。抓不到就直接說抓不到——開一場沒有逐字稿的會議
        // 比不開更糟，因為使用者是散會後才發現的。
        guard await models.prefetch() else {
            lastError = models.error
            // 使用者自己按取消不是故障，回設定畫面就好；`error` 有值才是真的壞了。
            phase = models.error == nil ? .idle : .failed
            return
        }

        let meetingID = "m\(Int(Date().timeIntervalSince1970 * 1000))"
        log = EventLog(meetingID: meetingID, scenario: scenario.rawValue)
        analyst = Analyst(scenario: scenario.rawValue)

        // 事件的唯一出口。所有事件都走這裡，才不會有哪條路徑漏記。
        let sink: @Sendable ([String: Any]) -> Void = { [weak self] event in
            Task { @MainActor in self?.receive(event) }
        }
        let asr = ASREngine(emit: sink)
        let diarizer = Diarizer(emit: sink)
        self.asr = asr
        self.diarizer = diarizer

        capture.onFrame = { [weak self] pcm in
            Task { @MainActor in self?.feed(pcm) }
        }
        let capturing = await capture.start(source: source)
        if !capturing {
            lastError = capture.lastError
            stop()
            return
        }

        // 兩顆模型分開載：ASR 先到就先開始轉錄，講者標籤晚一點沒關係。
        await asr.start(model: model, language: language, context: context)
        Task { await diarizer.start() }
    }

    func stop() {
        capture.stop()
        asr?.stop()
        Task { [diarizer, log] in
            await diarizer?.finish()
            await MainActor.run { log?.close() }
        }
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

    // MARK: - 音訊

    /// 收音永遠不等推論。模型還沒載完就先存著，`ready` 之後一次補上。
    private func feed(_ pcm: Data) {
        let samples = Self.pcmToFloat(pcm)
        guard ready else {
            if pending.count >= 600 { health.droppedBeforeReady += 1; return } // 60s 上限
            pending.append(samples)
            return
        }
        asr?.feed(samples)
        diarizer?.feed(samples)
    }

    private func flushPending() {
        for samples in pending {
            asr?.feed(samples)
            diarizer?.feed(samples)
        }
        pending = []
    }

    nonisolated static func pcmToFloat(_ raw: Data) -> [Float] {
        raw.withUnsafeBytes { buf in
            buf.bindMemory(to: Int16.self).map { Float(Int16(littleEndian: $0)) / 32768.0 }
        }
    }

    // MARK: - 事件

    /// 引擎事件的唯一入口：先落地，再更新畫面，順便決定要不要跑一輪分析。
    private func receive(_ ev: [String: Any]) {
        log?.log(ev)
        handle(ev)

        guard ev["type"] as? String == "final", let analyst,
              let text = ev["text"] as? String else { return }
        let at = audioMs
        Task {
            await analyst.addFinal(text)
            if await analyst.shouldRun() {
                await analyst.run(atMs: at) { [weak self] event in
                    Task { @MainActor in self?.receive(event) }
                }
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
