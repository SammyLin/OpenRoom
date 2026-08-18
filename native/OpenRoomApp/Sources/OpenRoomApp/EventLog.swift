import Foundation

/// 一場會議的事件檔，`openroom/server.py` 裡 `Session.log` 的移植。
///
/// 不落地就沒得標註 insight 品質，也沒得回頭看「那句話當時是怎麼斷的」。
/// 用 jsonl 不用 SQLite：單機、一次一場、寫完只讀一次，schema 跟 migration
/// 都是為不存在的問題付錢。
///
/// 每個 run 目錄裡有三個檔：
///   - `events.jsonl`：全部事件，debug 用的原始資料。
///   - `transcript.txt`：逐字稿，每收到一句 final 就 append——當掉了也留得住，
///     而不是收工那一刻才一次寫出去（那等於「當掉就整場不見」）。
///   - `meeting.json`：給歷史清單看的摘要。沒有它清單就得每次掃完整份 jsonl。
final class EventLog {
    let directory: URL
    private var handle: FileHandle?
    private var transcript: FileHandle?
    private let startedAt = Date()
    private let meetingID: String
    private let scenario: String
    private var title = ""
    private var durationMs = 0
    private var finals = 0
    private var speakers = 0

    /// `runs/` 之前掛在 repo 底下。現在沒有 repo 可掛，改用 Application Support——
    /// .app 可能被拖到 /Applications，那裡不能寫。
    static func defaultRunsDirectory() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory,
                                            in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory())
        return base.appendingPathComponent("OpenRoom/runs", isDirectory: true)
    }

    init?(meetingID: String, scenario: String = "",
          runsDir: URL = EventLog.defaultRunsDirectory()) {
        let stamp = {
            let f = DateFormatter()
            f.dateFormat = "yyyyMMdd-HHmmss"
            return f.string(from: Date())
        }()
        self.meetingID = meetingID
        self.scenario = scenario
        directory = runsDir.appendingPathComponent("\(stamp)-\(meetingID)", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            handle = try Self.openForAppending(directory.appendingPathComponent("events.jsonl"))
            transcript = try Self.openForAppending(directory.appendingPathComponent("transcript.txt"))
        } catch {
            return nil
        }
    }

    private static func openForAppending(_ url: URL) throws -> FileHandle {
        FileManager.default.createFile(atPath: url.path, contents: nil)
        let h = try FileHandle(forWritingTo: url)
        try h.seekToEnd()
        return h
    }

    /// 每一個送給 UI 的事件都留一份，順便把歷史清單要的摘要累積起來。
    func log(_ event: [String: Any]) {
        guard let handle else { return }
        var line = event
        line["_wall_ms"] = Int(Date().timeIntervalSince(startedAt) * 1000)
        if let data = try? JSONSerialization.data(withJSONObject: line,
                                                 options: [.withoutEscapingSlashes]),
           let text = String(data: data, encoding: .utf8) {
            // 會議中途看得到，而且當掉不會整份不見
            try? handle.write(contentsOf: Data((text + "\n").utf8))
        }

        switch event["type"] as? String {
        case "final":
            guard let text = (event["text"] as? String), !text.isEmpty else { return }
            finals += 1
            durationMs = max(durationMs, (event["end_ms"] as? NSNumber)?.intValue ?? 0)
            if title.isEmpty { title = String(text.prefix(80)) }
            try? transcript?.write(contentsOf: Data((text + "\n").utf8))
        case "speaker_turns":
            speakers = max(speakers, (event["speakers"] as? NSNumber)?.intValue ?? 0)
        default:
            break
        }
    }

    func close() {
        writeManifest()
        try? transcript?.close()
        transcript = nil
        try? handle?.close()
        handle = nil
    }

    /// 摘要只在收工時寫一次。中途當掉就沒有這個檔——`MeetingArchive` 認得那種目錄，
    /// 會退回用目錄名的時間戳跟 transcript.txt 的第一行，不會讓那場會議從清單上消失。
    private func writeManifest() {
        let manifest: [String: Any] = [
            "meeting_id": meetingID,
            "scenario": scenario,
            "started_at": startedAt.timeIntervalSince1970,
            "duration_ms": durationMs,
            "segments": finals,
            "speakers": speakers,
            "title": title,
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: manifest,
                                                    options: [.withoutEscapingSlashes]) else { return }
        try? data.write(to: directory.appendingPathComponent("meeting.json"))
    }
}
