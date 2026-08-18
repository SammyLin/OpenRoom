import SwiftUI
import AppKit

struct ContentView: View {
    @StateObject private var session = MeetingSession()
    @StateObject private var permissions = PermissionsManager()
    @State private var source: AudioSource = .system
    @State private var scenario: Scenario = .discussion
    @State private var busy = false
    @State private var showHistory = false
    /// 拿著才取消得掉。第一次啟動的「開始」有一段是下載 ~1GB。
    @State private var startTask: Task<Void, Never>?
    @AppStorage("openroom.retention.days") private var retentionDays = 0
    /// autostart 只開一場。`onAppear` 會隨著 phase 切換再跑一次，沒有這個旗標的話
    /// 失敗一次就變成無止盡重試（實測 25 秒重試了四遍）。
    @State private var autostarted = false
    // 螢幕錄製沒過就直接跳「開始」，只會在畫面上收到一行英文系統錯誤——onboarding
    // 沒過（且還沒手動跳過）之前，先擋在設定畫面前面把權限講清楚。
    @AppStorage("openroom.onboarding.skipped") private var onboardingSkipped = false

    var body: some View {
        Group {
            if !permissions.screenRecordingGranted && !onboardingSkipped {
                OnboardingView(permissions: permissions) { onboardingSkipped = true }
            } else {
                mainFlow
            }
        }
        .onAppear {
            // 測試用 hook：沒有 Accessibility 權限沒法自動化點按鈕，這裡讓
            // `OPENROOM_AUTOSTART=system` / `mic` 直接跳過 UI 開一場會議。不是給
            // 使用者用的功能，只在有這個環境變數時才會動。
            // 過期的會議在這裡清掉。一天只會變一次的事不值得一個計時器守著。
            if let retention = MeetingArchive.Retention(rawValue: retentionDays) {
                MeetingArchive.cleanup(retention)
            }
            guard !autostarted,
                  let raw = ProcessInfo.processInfo.environment["OPENROOM_AUTOSTART"],
                  let auto = AudioSource(rawValue: raw) else { return }
            autostarted = true
            source = auto
            start()
        }
        .frame(minWidth: 760, minHeight: 520)
    }

    @ViewBuilder private var mainFlow: some View {
        let nothingRecorded = session.segments.isEmpty
        if session.phase == .idle
            || ((session.phase == .failed || session.phase == .stopped) && nothingRecorded) {
            SetupView(source: $source, scenario: $scenario,
                      error: session.lastError ?? session.health.errors.last?.message, busy: busy,
                      download: session.models.statusLine.map { ($0, session.models.fraction) },
                      onStart: { start() },
                      onCancel: { startTask?.cancel() },
                      onHistory: { showHistory = true })
                .sheet(isPresented: $showHistory) {
                    HistoryView { showHistory = false }
                }
        } else {
            LiveView(session: session, scenarioLabel: scenario.label,
                     onStop: { session.stop() }, onExport: { export() })
        }
    }

    private func start() {
        busy = true
        startTask = Task {
            // 語言給 nil = 讓模型自己判斷，中英夾雜的會議需要這樣。
            await session.start(source: source, scenario: scenario,
                                model: ModelStore.asr.repo, language: nil)
            busy = false
            startTask = nil
        }
    }

    private func export() {
        saveText(session.exportMarkdown(),
                 suggested: "openroom-\(Int(Date().timeIntervalSince1970)).md")
    }
}
