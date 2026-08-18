import Foundation

/// `OpenRoom --selfcheck`：純邏輯的驗證，不碰模型、不收音、不打網路。
///
/// 移植過來的三段邏輯都在這裡驗：Analyst 的 JSON 挖取與節流、簡轉繁、PCM 轉換。
/// 跟 Python 版 `_selfcheck()` 同一個用意——非顯而易見的邏輯要留一個跑得動的檢查。
enum SelfCheck {
    static func run() -> Int32 {
        // JSON 挖取：模型常常加 markdown 圍欄
        let fenced = """
            ```json
            {"headline":"談 CI 快取","items":[{"kind":"context","text":"GitLab 的 cache key"}],
             "questions":["快取失效怎麼處理？"]}
            ```
            """
        guard let parsed = Analyst.insight(fromText: fenced) else { return fail("圍欄 JSON 解不出來") }
        guard parsed.headline == "談 CI 快取" else { return fail("headline 錯：\(parsed.headline)") }
        guard parsed.items.first?.kind == "context", parsed.questions.count == 1 else {
            return fail("items/questions 解析錯")
        }
        guard Analyst.insight(fromText: "not json") == nil else { return fail("非 JSON 應該回 nil") }

        // 上限：items 最多 4、questions 最多 3
        let many = #"{"headline":"h","items":[{"text":"1"},{"text":"2"},{"text":"3"},{"text":"4"},{"text":"5"}],"questions":["a","b","c","d"]}"#
        guard let capped = Analyst.insight(fromText: many),
              capped.items.count == 4, capped.questions.count == 3 else {
            return fail("items/questions 沒有截斷")
        }

        // Anthropic 回應的文字抽取
        let blocks: [String: Any] = ["content": [["type": "text", "text": "hi "],
                                                 ["type": "text", "text": "there"]]]
        guard Analyst.textFromAnthropic(blocks) == "hi there" else { return fail("Anthropic 文字抽取錯") }
        guard Analyst.textFromAnthropic(["content": []]) == "" else { return fail("空 content 應該給空字串") }

        // 簡轉繁：使用者是台灣人，拿簡體當 reference 每個字都算一次取代，WER 被灌水
        guard ASREngine.toTraditional("这是简体") == "這是簡體" else {
            return fail("簡轉繁沒生效：\(ASREngine.toTraditional("这是简体"))")
        }
        guard ASREngine.toTraditional("plain english") == "plain english" else {
            return fail("英文應該原封不動")
        }

        // PCM：s16le little-endian → -1.0…1.0
        let pcm = Data([0x00, 0x00, 0x00, 0x40, 0x00, 0xC0])   // 0, +16384, -16384
        let floats = MeetingSession.pcmToFloat(pcm)
        guard floats.count == 3, floats[0] == 0,
              abs(floats[1] - 0.5) < 0.001, abs(floats[2] + 0.5) < 0.001 else {
            return fail("PCM 轉換錯：\(floats)")
        }

        // 歷史清單的目錄名解析。解錯的下場是「那場會議從清單上消失」，
        // 而且不會有任何錯誤訊息——正好是最難發現的那種壞法。
        guard let parsedDate = MeetingArchive.timestamp(fromDirectoryName: "20260818-142530-m1755500000000") else {
            return fail("run 目錄的時間戳解不出來")
        }
        let parts = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute, .second],
                                                    from: parsedDate)
        guard parts.year == 2026, parts.month == 8, parts.day == 18,
              parts.hour == 14, parts.minute == 25, parts.second == 30 else {
            return fail("時間戳解錯：\(parts)")
        }
        guard MeetingArchive.timestamp(fromDirectoryName: "not-a-run-dir") == nil else {
            return fail("不是 run 目錄的名字應該回 nil")
        }

        // 一場會議寫出去再讀回來，摘要要對得起來。這條路斷了，歷史清單就是空的。
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("openroom-selfcheck-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: tmp) }
        guard let log = EventLog(meetingID: "mtest", scenario: "discussion", runsDir: tmp) else {
            return fail("EventLog 開不起來")
        }
        log.log(["type": "final", "text": "第一句", "start_ms": 0, "end_ms": 1200])
        log.log(["type": "final", "text": "第二句", "start_ms": 1200, "end_ms": 4500])
        log.log(["type": "speaker_turns", "speakers": 2, "turns": []])
        log.close()
        let records = MeetingArchive.list(runsDir: tmp)
        guard records.count == 1, let rec = records.first else {
            return fail("歷史清單應該有一場會議，實際 \(records.count)")
        }
        guard rec.title == "第一句", rec.segments == 2, rec.speakers == 2,
              rec.durationMs == 4500, !rec.recovered else {
            return fail("摘要對不上：\(rec)")
        }
        guard MeetingArchive.transcript(rec) == "第一句\n第二句\n" else {
            return fail("逐字稿對不上：\(MeetingArchive.transcript(rec))")
        }

        // 保留期限：挑錯就是刪掉使用者要留的東西，或者留下他要它消失的東西。
        guard MeetingArchive.stale(.forever, runsDir: tmp).isEmpty else {
            return fail("「永久保留」不該挑出任何東西")
        }
        let inThirtyOneDays = rec.startedAt.addingTimeInterval(31 * 86_400)
        guard MeetingArchive.stale(.days30, now: inThirtyOneDays, runsDir: tmp).count == 1 else {
            return fail("31 天後 30 天期限應該挑出那場會議")
        }
        guard MeetingArchive.stale(.days90, now: inThirtyOneDays, runsDir: tmp).isEmpty else {
            return fail("31 天後 90 天期限不該挑出任何東西")
        }

        print("selfcheck ok")
        return 0
    }

    private static func fail(_ message: String) -> Int32 {
        FileHandle.standardError.write(Data("selfcheck FAILED: \(message)\n".utf8))
        return 1
    }
}
