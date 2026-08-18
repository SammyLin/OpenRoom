import Foundation

/// 即時分析層，`openroom/analyst.py` 的移植。逐字稿只是原料，這層才是這個工具存在的理由。
///
/// **分析永遠不會擋到收音或逐字稿**：跑在自己的 Task，同時只跑一輪，上一輪還沒回來就
/// 跳過並送出看得到的事件——不是靜靜地不做。
///
/// 事件格式跟 Python 版一致（`insight_pending` / `insight` / `insight_none` /
/// `insight_error`），`MeetingSession.handle` 不用改。
actor Analyst {
    /// 一輪分析要看多少最近的逐字稿。太短沒有上下文，太長浪費 token 又拖慢。
    static let contextChars = 3_000
    /// 累積多少新字才值得再問一次。開會語速大約每分鐘 200–300 字。
    static let triggerChars = 400
    /// 兩輪之間的最短間隔，避免話密的時候一直打 API。
    static let minInterval: TimeInterval = 25
    static let timeout: TimeInterval = 90
    /// 記得前幾輪講過什麼。太少會重複，太多會吃掉逐字稿的上下文空間。
    static let memoryChars = 1_500

    struct Scenario {
        let label: String
        let brief: String
    }

    static let scenarios: [String: Scenario] = [
        "interview": Scenario(
            label: "面試",
            brief: "你在旁聽一場面試。針對最近這段對話，判斷受訪者說的內容是否正確、"
                 + "有沒有含糊或跳過的地方，並建議面試官接下來該追問什麼。"
                 + "技術說法有錯就直接指出錯在哪。"),
        "discussion": Scenario(
            label: "討論會議",
            brief: "你在旁聽一場工作會議。針對最近這段討論，補充與會者會需要的背景資料："
                 + "被提到的工具、專有名詞、版本、數字、前後脈絡。"
                 + "有不確定或值得查證的說法就標出來。"),
    ]

    static let outputContract = """
        只輸出 JSON，不要有其他文字、不要 markdown 圍欄。格式：
        {"headline": "一句話說明這段在談什麼",
         "items": [{"kind": "fact|correction|context|risk", "text": "一到兩句"}],
         "questions": ["建議追問的問題"]}
        items 最多 4 個，questions 最多 3 個。**只講新的東西**：已經講過的背景、已經指出過的
        辨識錯誤、已經問過的問題，一律不要再講一次。沒有新東西就把 items 跟 questions 都給
        空陣列，這是正常結果，不是失敗。
        用繁體中文，除了專有名詞。
        """

    var scenario: String
    let model: String
    let webSearch: Bool
    let provider: String

    private var transcript: [String] = []
    /// 講過的話要記得。實測 19 輪的會議裡「marketplace 是集中發布」講了 13 次——
    /// 不是模型笨，是每輪都從零開始看逐字稿。
    private var said: [String] = []
    private var charsSince = 0
    private var lastRun: Date = .distantPast
    private var running = false

    init(scenario: String = "discussion", model: String = "claude-sonnet-5",
         webSearch: Bool = true, env: [String: String] = ProcessInfo.processInfo.environment) {
        self.scenario = scenario
        self.model = model
        self.webSearch = webSearch
        self.provider = env["OPENROOM_LLM_PROVIDER"] ?? "claude-cli"
    }

    func setScenario(_ name: String) {
        if Self.scenarios[name] != nil { scenario = name }
    }

    func addFinal(_ text: String) {
        transcript.append(text)
        charsSince += text.count
    }

    func shouldRun(now: Date = Date()) -> Bool {
        if running || charsSince < Self.triggerChars { return false }
        return now.timeIntervalSince(lastRun) >= Self.minInterval
    }

    var hasPending: Bool { charsSince > 0 && !running }

    func prompt() -> String {
        let joined = String(transcript.joined(separator: " ").suffix(Self.contextChars))
        let brief = (Self.scenarios[scenario] ?? Self.scenarios["discussion"]!).brief
        let extra = webSearch ? "需要查證外部事實時可以用 WebSearch，但不要為了查而查。\n" : ""
        let saidText = String(said.joined(separator: " / ").suffix(Self.memoryChars))
        let memory = saidText.isEmpty ? ""
            : "\n你在這場會議已經講過這些，不要再講一次：\n---\n\(saidText)\n---\n"
        return "\(brief)\n\n\(extra)\(memory)\n逐字稿（可能有辨識錯誤，請容錯理解）："
             + "\n---\n\(joined)\n---\n\n\(Self.outputContract)"
    }

    /// 跑一輪分析。`emit` 收 protocol 事件。
    func run(atMs audioMs: Int, emit: @escaping ([String: Any]) -> Void) async {
        running = true
        charsSince = 0
        lastRun = Date()
        let t0 = Date()
        defer { running = false }

        // 分析要好幾秒，期間 UI 必須知道「有東西在跑」，不然看起來像當掉
        emit(["type": "insight_pending", "scenario": scenario, "at_ms": audioMs])

        let body: String
        do {
            body = try await callProvider(prompt())
        } catch let err as LLMError {
            emit(["type": "insight_error", "code": err.code,
                  "message": String(err.message.prefix(300))])
            return
        } catch {
            emit(["type": "insight_error", "code": "llm_failed", "message": "\(error)"])
            return
        }

        guard let insight = Self.insight(fromText: body) else {
            emit(["type": "insight_error", "code": "llm_bad_output",
                  "message": "模型沒有回傳可解析的 JSON"])
            return
        }

        let latency = Int(Date().timeIntervalSince(t0) * 1000)
        if insight.items.isEmpty && insight.questions.isEmpty {
            // 沒有新東西是正常結果。但也不能靜靜地什麼都不做——UI 得知道這輪跑完了。
            emit(["type": "insight_none", "at_ms": audioMs, "latency_ms": latency])
            return
        }

        said.append(insight.headline + "：" + insight.items.map(\.text).joined(separator: "；"))
        emit(["type": "insight", "scenario": scenario, "headline": insight.headline,
              "items": insight.items.map { ["kind": $0.kind, "text": $0.text] },
              "questions": insight.questions, "at_ms": audioMs, "latency_ms": latency])
    }

    // MARK: - Providers

    struct LLMError: Error {
        let code: String
        let message: String
    }

    private func callProvider(_ prompt: String) async throws -> String {
        let env = ProcessInfo.processInfo.environment
        switch provider {
        case "claude-cli":
            return try await Self.runCLI("claude", prompt: prompt, model: model, webSearch: webSearch)
        case "cli":
            return try await Self.runCLI(env["OPENROOM_LLM_CLI"] ?? "claude",
                                         prompt: prompt, model: model, webSearch: webSearch)
        case "anthropic-api":
            return try await Self.callAnthropic(prompt, model: model, webSearch: webSearch, env: env)
        case "ollama":
            return try await Self.callOllama(prompt, model: env["OPENROOM_OLLAMA_MODEL"] ?? "llama3.1",
                                             env: env)
        default:
            throw LLMError(code: "llm_config", message: "未知的 OPENROOM_LLM_PROVIDER：\(provider)")
        }
    }

    /// 跑一個相容 `claude -p ... --output-format json` 合約的 CLI。
    /// 這台機器不見得有 ANTHROPIC_API_KEY，但 Claude Code 已經登入過，CLI 直接借用那份授權。
    static func runCLI(_ binary: String, prompt: String, model: String,
                       webSearch: Bool) async throws -> String {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/nice")
        var args = ["-n", "15", binary, "-p", prompt, "--model", model, "--output-format", "json"]
        if webSearch { args += ["--allowed-tools", "WebSearch"] }
        proc.arguments = args
        let out = Pipe(), err = Pipe()
        proc.standardOutput = out
        proc.standardError = err

        do {
            try proc.run()
        } catch {
            throw LLMError(code: "llm_failed", message: "啟動 \(binary) 失敗：\(error)")
        }

        // 逾時要真的殺掉：CLI 是獨立的重量級 process，不殺會在收工後繼續吃 CPU。
        let killer = Task {
            try? await Task.sleep(for: .seconds(timeout))
            if proc.isRunning { proc.terminate() }
        }
        let outData = out.fileHandleForReading.readDataToEndOfFile()
        let errData = err.fileHandleForReading.readDataToEndOfFile()
        proc.waitUntilExit()
        let timedOut = killer.isCancelled == false && proc.terminationReason == .uncaughtSignal
        killer.cancel()

        if timedOut {
            throw LLMError(code: "llm_timeout", message: "分析超過 \(Int(timeout)) 秒沒回應")
        }
        guard proc.terminationStatus == 0 else {
            let msg = String(data: errData, encoding: .utf8) ?? ""
            throw LLMError(code: "llm_failed", message: msg.isEmpty ? "\(binary) CLI 失敗" : msg)
        }
        guard let envelope = try? JSONSerialization.jsonObject(with: outData) as? [String: Any],
              let body = envelope["result"] as? String else {
            throw LLMError(code: "llm_bad_output", message: "\(binary) 輸出缺少 result 欄位")
        }
        return body
    }

    static func callAnthropic(_ prompt: String, model: String, webSearch: Bool,
                              env: [String: String]) async throws -> String {
        guard let key = env["ANTHROPIC_API_KEY"] else {
            throw LLMError(code: "llm_config", message: "ANTHROPIC_API_KEY 沒有設定")
        }
        var body: [String: Any] = [
            "model": model, "max_tokens": 1024,
            "messages": [["role": "user", "content": prompt]],
        ]
        if webSearch {
            body["tools"] = [["type": "web_search_20260209", "name": "web_search"]]
        }
        var req = URLRequest(url: URL(string: "https://api.anthropic.com/v1/messages")!)
        req.httpMethod = "POST"
        req.timeoutInterval = timeout
        req.setValue(key, forHTTPHeaderField: "x-api-key")
        req.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        req.setValue("application/json", forHTTPHeaderField: "content-type")
        req.httpBody = try JSONSerialization.data(withJSONObject: body)

        let data = try await Self.post(req, what: "Anthropic API")
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw LLMError(code: "llm_bad_output", message: "Anthropic API 回傳的不是 JSON")
        }
        if obj["stop_reason"] as? String == "refusal" {
            throw LLMError(code: "llm_failed", message: "Anthropic API 拒絕了這次請求（refusal）")
        }
        let text = textFromAnthropic(obj)
        guard !text.isEmpty else {
            throw LLMError(code: "llm_bad_output", message: "Anthropic API 沒有回傳文字內容")
        }
        return text
    }

    static func callOllama(_ prompt: String, model: String, env: [String: String]) async throws -> String {
        let host = (env["OLLAMA_HOST"] ?? "http://localhost:11434")
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard let url = URL(string: "\(host)/api/generate") else {
            throw LLMError(code: "llm_config", message: "OLLAMA_HOST 不是合法網址：\(host)")
        }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.timeoutInterval = timeout
        req.setValue("application/json", forHTTPHeaderField: "content-type")
        req.httpBody = try JSONSerialization.data(
            withJSONObject: ["model": model, "prompt": prompt, "stream": false])

        let data = try await Self.post(req, what: "Ollama（\(host)）")
        let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        let text = obj?["response"] as? String ?? ""
        guard !text.isEmpty else {
            throw LLMError(code: "llm_bad_output", message: "Ollama 沒有回傳文字內容")
        }
        return text
    }

    private static func post(_ req: URLRequest, what: String) async throws -> Data {
        do {
            return try await URLSession.shared.data(for: req).0
        } catch let err as URLError where err.code == .timedOut {
            throw LLMError(code: "llm_timeout", message: "分析超過 \(Int(timeout)) 秒沒回應")
        } catch {
            throw LLMError(code: "llm_failed", message: "\(what) 呼叫失敗：\(error.localizedDescription)")
        }
    }

    static func textFromAnthropic(_ data: [String: Any]) -> String {
        let blocks = data["content"] as? [[String: Any]] ?? []
        return blocks.filter { $0["type"] as? String == "text" }
            .compactMap { $0["text"] as? String }
            .joined()
    }

    // MARK: - 解析

    struct Item { let kind: String; let text: String }
    struct Parsed { let headline: String; let items: [Item]; let questions: [String] }

    /// 從模型輸出的文字裡挖出 JSON。模型偶爾會加 markdown 圍欄，剝掉再解析。
    static func insight(fromText raw: String) -> Parsed? {
        var body = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if body.hasPrefix("```") {
            body = body.drop(while: { $0 != "\n" }).dropFirst().description
            if let fence = body.range(of: "```", options: .backwards) {
                body = String(body[body.startIndex..<fence.lowerBound])
            }
        }
        guard let start = body.firstIndex(of: "{"), let end = body.lastIndex(of: "}"),
              start < end,
              let data = String(body[start...end]).data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }

        let items = (obj["items"] as? [[String: Any]] ?? [])
            .compactMap { row -> Item? in
                guard let text = row["text"] as? String, !text.isEmpty else { return nil }
                return Item(kind: row["kind"] as? String ?? "", text: text)
            }
            .prefix(4)
        let questions = (obj["questions"] as? [String] ?? [])
            .filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
            .prefix(3)
        return Parsed(headline: (obj["headline"] as? String ?? "")
                        .trimmingCharacters(in: .whitespacesAndNewlines),
                      items: Array(items), questions: Array(questions))
    }
}
