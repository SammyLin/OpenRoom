import SwiftUI

struct SetupView: View {
    @Binding var source: AudioSource
    @Binding var scenario: Scenario
    let backendState: BackendManager.State
    let error: String?
    let busy: Bool
    let onStart: () -> Void

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

                backendStatus

                if let error {
                    Label(error, systemImage: "exclamationmark.triangle.fill")
                        .font(.caption).foregroundStyle(.red)
                }

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
                .disabled(busy || backendState != .ready)
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

    @ViewBuilder private var backendStatus: some View {
        switch backendState {
        case .notStarted, .starting:
            statusPill(icon: "hourglass",
                       text: L("Starting backend (the first run warms up the model, about 45 seconds)…"),
                       tint: .secondary)
        case .ready:
            statusPill(icon: "checkmark.circle.fill", text: L("Backend ready"), tint: .green)
        case .failed(let msg):
            statusPill(icon: "xmark.octagon.fill", text: msg, tint: .red)
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
