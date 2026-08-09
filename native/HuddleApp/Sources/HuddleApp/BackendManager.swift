import Foundation

/// Phase 1：ASR/diarization 還是 Python（Qwen3-ASR MLX + pyannote），這支只是把它
/// 包成 sidecar，App 自己 spawn，使用者不用開終端機打 `python -m huddle.server`。
///
/// ponytail: 沒做「把 venv/模型一起塞進 .app bundle」——那是分發用的工程，這是單機
/// 個人工具，repo 路徑固定在這台機器上就夠。之後真的要換 CoreML ASR（Phase 2）
/// 這支就整個退休。
final class BackendManager: ObservableObject {
    enum State: Equatable {
        case notStarted, starting, ready, failed(String)
    }

    @Published var state: State = .notStarted
    private var process: Process?

    /// 專案根目錄。先看環境變數，沒有就退回開發機的固定路徑。
    private var repoRoot: URL {
        if let override = ProcessInfo.processInfo.environment["HUDDLE_REPO_PATH"] {
            return URL(fileURLWithPath: override)
        }
        return URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent("workspaces/slab/huddle")
    }

    func ensureRunning() {
        if state == .ready || state == .starting { return }
        if portOpen(8000) {
            state = .ready // 已經有人手動起了 server，不用搶著再開一個
            return
        }
        let python = repoRoot.appendingPathComponent(".venv/bin/python")
        guard FileManager.default.fileExists(atPath: python.path) else {
            state = .failed("找不到 \(python.path)——先在 repo 跑 `uv venv --python 3.11`")
            return
        }
        state = .starting
        let p = Process()
        p.executableURL = python
        p.arguments = ["-m", "huddle.server"]
        p.currentDirectoryURL = repoRoot
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = pipe
        p.terminationHandler = { [weak self] proc in
            DispatchQueue.main.async {
                if proc.terminationStatus != 0, case .starting = self?.state ?? .notStarted {
                    self?.state = .failed("後端 process 意外結束（exit \(proc.terminationStatus)）")
                }
            }
        }
        do {
            try p.run()
            process = p
        } catch {
            state = .failed("啟動不了 python -m huddle.server: \(error)")
            return
        }
        pollUntilReady()
    }

    private func pollUntilReady(elapsed: Double = 0) {
        // 冷啟動預熱最長量過 46 秒，這裡給 90 秒上限，跟 ws client 端 ready 逾時一致。
        if portOpen(8000) {
            DispatchQueue.main.async { self.state = .ready }
            return
        }
        if elapsed > 90 {
            DispatchQueue.main.async { self.state = .failed("後端 90 秒沒開起 port 8000") }
            return
        }
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.5) {
            self.pollUntilReady(elapsed: elapsed + 0.5)
        }
    }

    func shutdown() {
        process?.terminate()
        process = nil
    }

    private func portOpen(_ port: UInt16) -> Bool {
        let sock = socket(AF_INET, SOCK_STREAM, 0)
        defer { close(sock) }
        guard sock >= 0 else { return false }
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = port.bigEndian
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")
        let result = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(sock, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        return result == 0
    }
}
