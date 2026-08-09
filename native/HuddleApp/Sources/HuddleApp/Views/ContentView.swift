import SwiftUI
import AppKit

struct ContentView: View {
    @StateObject private var backend = BackendManager()
    @StateObject private var session = MeetingSession()
    @StateObject private var permissions = PermissionsManager()
    @State private var source: AudioSource = .system
    @State private var scenario: Scenario = .discussion
    @State private var busy = false
    // 螢幕錄製沒過就直接跳「開始」，只會在畫面上收到一行英文系統錯誤——onboarding
    // 沒過（且還沒手動跳過）之前，先擋在設定畫面前面把權限講清楚。
    @AppStorage("huddle.onboarding.skipped") private var onboardingSkipped = false

    var body: some View {
        Group {
            if !permissions.screenRecordingGranted && !onboardingSkipped {
                OnboardingView(permissions: permissions) { onboardingSkipped = true }
            } else {
                mainFlow
            }
        }
        .onAppear { backend.ensureRunning() }
        .onChange(of: backend.state) { s in
            // 測試用 hook：沒有 Accessibility 權限沒法自動化點按鈕，這裡讓
            // `HUDDLE_AUTOSTART=system` / `mic` 直接跳過 UI 開一場會議。不是給
            // 使用者用的功能，只在有這個環境變數時才會動。
            guard s == .ready, let raw = ProcessInfo.processInfo.environment["HUDDLE_AUTOSTART"],
                  let auto = AudioSource(rawValue: raw) else { return }
            source = auto
            Task { await start() }
        }
        .frame(minWidth: 760, minHeight: 520)
    }

    @ViewBuilder private var mainFlow: some View {
        let nothingRecorded = session.segments.isEmpty
        if session.phase == .idle
            || ((session.phase == .failed || session.phase == .stopped) && nothingRecorded) {
            SetupView(source: $source, scenario: $scenario, backendState: backend.state,
                      error: session.lastError ?? session.health.errors.last?.message, busy: busy) {
                Task { await start() }
            }
        } else {
            LiveView(session: session, scenarioLabel: scenario.label,
                     onStop: { session.stop() }, onExport: { export() })
        }
    }

    private func start() async {
        busy = true
        await session.start(host: "127.0.0.1", port: 8000, source: source, scenario: scenario)
        busy = false
    }

    private func export() {
        let md = session.exportMarkdown()
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "huddle-\(Int(Date().timeIntervalSince1970)).md"
        panel.allowedContentTypes = [.plainText]
        if panel.runModal() == .OK, let url = panel.url {
            try? md.write(to: url, atomically: true, encoding: .utf8)
        }
    }
}
