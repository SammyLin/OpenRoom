import SwiftUI

struct SetupView: View {
    @Binding var source: AudioSource
    @Binding var scenario: Scenario
    let error: String?
    let busy: Bool
    /// 下載進度那一行。nil = 沒有下載在跑（模型都在快取裡）。
    let download: (line: String, fraction: Double)?
    let onStart: () -> Void
    let onCancel: () -> Void
    let onHistory: () -> Void

    var body: some View {
        ZStack {
            Color(nsColor: .windowBackgroundColor).ignoresSafeArea()
            VStack(alignment: .leading, spacing: 28) {
                header

                section(title: L("What kind of session is this")) {
                    HStack(spacing: 10) {
                        ForEach(Scenario.allCases, id: \.self) { sc in
                            pickCard(icon: sc.icon, title: sc.label, detail: sc.detail,
                                     selected: scenario == sc) { scenario = sc }
                        }
                    }
                }

                section(title: L("Where is the audio coming from")) {
                    VStack(spacing: 10) {
                        pickCard(icon: AudioSource.system.icon, title: L("System audio"),
                                 detail: L("ScreenCaptureKit taps the system output, so Meet and Teams both work, browser or desktop app."),
                                 selected: source == .system, full: true) { source = .system }
                        pickCard(icon: AudioSource.mic.icon, title: L("Microphone"),
                                 detail: L("A physical meeting room, one microphone for everyone."),
                                 selected: source == .mic, full: true) { source = .mic }
                    }
                }

                if let error {
                    Label(error, systemImage: "exclamationmark.triangle.fill")
                        .font(.caption).foregroundStyle(.red)
                }

                // 第一次啟動要抓 ~1GB。不畫出來的話畫面只有一顆轉圈，跟當掉長得一樣。
                if let download {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(download.line).font(.caption).foregroundStyle(.secondary)
                        ProgressView(value: download.fraction)
                        Text(L("Models are downloaded once and reused. Quitting is safe — the download resumes."))
                            .font(.caption2).foregroundStyle(.secondary)
                    }
                }

                HStack(spacing: 10) {
                    Button(action: onStart) {
                        HStack(spacing: 8) {
                            if busy { ProgressView().controlSize(.small) }
                            Text(busy ? L("Connecting…") : L("Start"))
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 2)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .disabled(busy)

                    // 第一次啟動要抓 ~1GB。在飯店 wifi 上沒有退出的路，
                    // 唯一的辦法就是強制結束 app——那才是真的會弄壞下載的做法。
                    if busy {
                        Button(L("Cancel"), action: onCancel)
                            .buttonStyle(.bordered).controlSize(.large)
                    }
                }

                Button(action: onHistory) {
                    Label(L("Past meetings"), systemImage: "clock.arrow.circlepath")
                }
                .buttonStyle(.plain).font(.caption).foregroundStyle(.secondary)
            }
            .padding(36)
            .frame(maxWidth: 480)
        }
    }

    private var header: some View {
        HStack(spacing: 14) {
            ZStack {
                Circle().fill(Color.accentColor.opacity(0.15)).frame(width: 44, height: 44)
                Image(systemName: "waveform").font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(Color.accentColor)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(L("Start a meeting")).font(.system(size: 22, weight: .bold))
                Text(L("The transcript is produced on your machine. Audio never leaves this computer."))
                    .font(.callout).foregroundStyle(.secondary)
            }
        }
    }

    private func section<Content: View>(title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title).font(.subheadline.weight(.semibold)).foregroundStyle(.secondary)
            content()
        }
    }

    private func statusPill(icon: String, text: String, tint: Color) -> some View {
        Label(text, systemImage: icon)
            .font(.caption.weight(.medium))
            .foregroundStyle(tint)
            .padding(.horizontal, 10).padding(.vertical, 6)
            .background(Capsule().fill(tint.opacity(0.1)))
    }

    private func pickCard(icon: String, title: String, detail: String, selected: Bool, full: Bool = false,
                           action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: icon)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(selected ? Color.accentColor : .secondary)
                    .frame(width: 20)
                VStack(alignment: .leading, spacing: 3) {
                    Text(title).font(.subheadline.weight(.semibold))
                    Text(detail).font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if full { Spacer(minLength: 0) }
            }
            .padding(12)
            .frame(maxWidth: full ? .infinity : nil, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 10)
                .fill(selected ? Color.accentColor.opacity(0.10) : Color(nsColor: .controlBackgroundColor)))
            .overlay(RoundedRectangle(cornerRadius: 10)
                .stroke(selected ? Color.accentColor : Color(nsColor: .separatorColor), lineWidth: selected ? 1.5 : 1))
        }
        .buttonStyle(.plain)
    }
}
