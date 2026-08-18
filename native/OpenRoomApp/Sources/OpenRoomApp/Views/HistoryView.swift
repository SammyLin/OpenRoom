import AppKit
import SwiftUI

/// 過去的會議。清單一次讀完（一場會議一個小小的 meeting.json，幾百場也是幾毫秒），
/// 逐字稿點到才讀——一小時的會議是幾十 KB，沒必要全部先塞進記憶體。
struct HistoryView: View {
    let onClose: () -> Void
    @State private var records: [MeetingRecord] = []
    @State private var selection: MeetingRecord?
    @State private var text = ""
    @AppStorage("openroom.retention.days") private var retentionDays = 0

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if records.isEmpty {
                Spacer()
                Text(L("No past meetings yet. Every meeting you record shows up here."))
                    .font(.callout).foregroundStyle(.secondary)
                Spacer()
            } else {
                HStack(spacing: 0) {
                    list.frame(width: 260)
                    Divider()
                    detail.frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
        }
        .frame(minWidth: 720, minHeight: 480)
        .background(Color(nsColor: .windowBackgroundColor))
        .onAppear {
            records = MeetingArchive.list()
            select(records.first)
        }
    }

    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: "clock.arrow.circlepath").foregroundStyle(Color.accentColor)
            Text(L("Past meetings")).font(.headline)
            Spacer()
            Button(L("Show in Finder")) { if let selection { MeetingArchive.reveal(selection) } }
                .disabled(selection == nil)
            Button(L("Export")) { export() }
                .disabled(text.isEmpty)
            Button(role: .destructive) { delete() } label: { Text(L("Delete")) }
                .disabled(selection == nil)
            Picker(L("Keep recordings"), selection: $retentionDays) {
                ForEach(MeetingArchive.Retention.allCases) { r in
                    Text(r.label).tag(r.rawValue)
                }
            }
            .labelsHidden().frame(width: 190)
            .onChange(of: retentionDays) { _, days in
                // 改設定就立刻生效。留到下次開 app 的話，使用者會以為設定沒作用。
                guard let r = MeetingArchive.Retention(rawValue: days) else { return }
                MeetingArchive.cleanup(r)
                records = MeetingArchive.list()
                if let selection, !records.contains(where: { $0.id == selection.id }) {
                    select(records.first)
                }
            }
            Button(L("Close"), action: onClose).keyboardShortcut(.cancelAction)
        }
        .buttonStyle(.bordered)
        .padding(.horizontal, 16).padding(.vertical, 10)
        .background(.bar)
    }

    private var list: some View {
        List(records, selection: Binding(get: { selection?.id },
                                         set: { id in select(records.first { $0.id == id }) })) { r in
            VStack(alignment: .leading, spacing: 3) {
                Text(r.title.isEmpty ? L("(no transcript)") : r.title)
                    .font(.subheadline.weight(.medium)).lineLimit(2)
                HStack(spacing: 6) {
                    Text(r.startedAt.formatted(date: .abbreviated, time: .shortened))
                    if r.durationMs > 0 { Text(formatClock(r.durationMs)) }
                    if r.recovered {
                        // 中途當掉的那種。不標出來，使用者會以為那場就是這麼短。
                        Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                    }
                }
                .font(.caption).foregroundStyle(.secondary)
            }
            .padding(.vertical, 3)
            .tag(r.id)
        }
        .listStyle(.sidebar)
    }

    private var detail: some View {
        ScrollView {
            Text(text.isEmpty ? L("(no transcript)") : text)
                .font(.system(size: 13))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(20)
        }
    }

    private func select(_ record: MeetingRecord?) {
        selection = record
        text = record.map(MeetingArchive.transcript) ?? ""
    }

    private func export() {
        guard let selection else { return }
        saveText(text, suggested: "openroom-\(selection.id).txt")
    }

    private func delete() {
        guard let selection else { return }
        MeetingArchive.delete(selection)
        records.removeAll { $0.id == selection.id }
        select(records.first)
    }
}

/// 存檔對話框。歷史清單跟直播畫面都要用，所以只寫一次。
func saveText(_ text: String, suggested: String) {
    let panel = NSSavePanel()
    panel.nameFieldStringValue = suggested
    panel.allowedContentTypes = [.plainText]
    guard panel.runModal() == .OK, let url = panel.url else { return }
    try? text.write(to: url, atomically: true, encoding: .utf8)
}
