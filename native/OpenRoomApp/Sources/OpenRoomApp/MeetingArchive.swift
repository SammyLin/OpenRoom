import AppKit
import Foundation

/// 過去的會議。`EventLog` 一直有在寫檔，但沒有任何路徑讀回來——逐字稿等於「存在
/// Application Support 深處，只有知道路的人找得到」。這裡就是那條路。
struct MeetingRecord: Identifiable, Hashable {
    /// 目錄名（`20260818-142530-m1755...`），本來就唯一。
    var id: String { directory.lastPathComponent }
    let directory: URL
    let title: String
    let startedAt: Date
    let durationMs: Int
    let segments: Int
    let speakers: Int
    let scenario: String
    /// 沒有 meeting.json 的目錄：會議中途當掉，摘要是從目錄名跟逐字稿猜的。
    let recovered: Bool

    var transcriptURL: URL { directory.appendingPathComponent("transcript.txt") }
}

enum MeetingArchive {
    /// 新的在前面。壞掉的目錄（沒有逐字稿也沒有摘要）不列——那是啟動失敗留下的空殼，
    /// 列出來只會讓清單看起來像壞了。
    static func list(runsDir: URL = EventLog.defaultRunsDirectory()) -> [MeetingRecord] {
        let dirs = (try? FileManager.default.contentsOfDirectory(
            at: runsDir, includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles])) ?? []
        return dirs.compactMap(record(at:)).sorted { $0.startedAt > $1.startedAt }
    }

    static func record(at directory: URL) -> MeetingRecord? {
        let manifest = directory.appendingPathComponent("meeting.json")
        if let data = try? Data(contentsOf: manifest),
           let m = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] {
            return MeetingRecord(
                directory: directory,
                title: (m["title"] as? String) ?? "",
                startedAt: Date(timeIntervalSince1970: (m["started_at"] as? NSNumber)?.doubleValue ?? 0),
                durationMs: (m["duration_ms"] as? NSNumber)?.intValue ?? 0,
                segments: (m["segments"] as? NSNumber)?.intValue ?? 0,
                speakers: (m["speakers"] as? NSNumber)?.intValue ?? 0,
                scenario: (m["scenario"] as? String) ?? "",
                recovered: false)
        }
        // 摘要缺了就用手邊有的東西重建：時間從目錄名，標題從逐字稿第一行。
        let text = (try? String(contentsOf: directory.appendingPathComponent("transcript.txt"),
                                encoding: .utf8)) ?? ""
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              let started = timestamp(fromDirectoryName: directory.lastPathComponent) else { return nil }
        let lines = text.split(separator: "\n").map(String.init)
        return MeetingRecord(
            directory: directory,
            title: String((lines.first ?? "").prefix(80)),
            startedAt: started,
            durationMs: 0,
            segments: lines.count,
            speakers: 0,
            scenario: "",
            recovered: true)
    }

    /// `20260818-142530-m1755...` 的前 15 個字元。解不出來就是別人的目錄，不要猜。
    static func timestamp(fromDirectoryName name: String) -> Date? {
        guard name.count >= 15 else { return nil }
        let f = DateFormatter()
        f.dateFormat = "yyyyMMdd-HHmmss"
        return f.date(from: String(name.prefix(15)))
    }

    static func transcript(_ record: MeetingRecord) -> String {
        (try? String(contentsOf: record.transcriptURL, encoding: .utf8)) ?? ""
    }

    /// 丟到垃圾桶，不是 unlink：刪掉的是使用者唯一一份逐字稿，要救得回來。
    static func delete(_ record: MeetingRecord) {
        try? FileManager.default.trashItem(at: record.directory, resultingItemURL: nil)
    }

    /// 保留天數的選項。文字檔不佔空間，所以預設是「永久」——會議紀錄自己過期消失
    /// 是最糟的預設值。想要它消失的人才去設。
    enum Retention: Int, CaseIterable, Identifiable {
        case forever = 0, days30 = 30, days90 = 90

        var id: Int { rawValue }

        var label: String {
            switch self {
            case .forever: return L("Keep forever")
            case .days30: return L("Delete after 30 days")
            case .days90: return L("Delete after 90 days")
            }
        }
    }

    /// 過期的是哪幾場。挑跟刪分開，是為了 selfcheck 驗得起「挑對了沒有」，
    /// 而不用真的去動使用者的垃圾桶。
    static func stale(_ retention: Retention, now: Date = Date(),
                      runsDir: URL = EventLog.defaultRunsDirectory()) -> [MeetingRecord] {
        guard retention != .forever else { return [] }
        let cutoff = now.addingTimeInterval(-Double(retention.rawValue) * 86_400)
        return list(runsDir: runsDir).filter { $0.startedAt < cutoff }
    }

    /// 超過保留期限的會議丟到垃圾桶。回傳丟掉幾場。
    /// 每次開 app 跑一次就夠——不需要一個計時器守著一件一天只會變一次的事。
    @discardableResult
    static func cleanup(_ retention: Retention,
                        runsDir: URL = EventLog.defaultRunsDirectory()) -> Int {
        let expired = stale(retention, runsDir: runsDir)
        for record in expired { delete(record) }
        return expired.count
    }

    static func reveal(_ record: MeetingRecord) {
        NSWorkspace.shared.selectFile(record.transcriptURL.path,
                                      inFileViewerRootedAtPath: record.directory.path)
    }
}
