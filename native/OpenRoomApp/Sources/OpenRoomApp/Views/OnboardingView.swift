import SwiftUI

/// 第一次開 app、或螢幕錄製權限還沒過，先講清楚要授權什麼，別讓使用者點「開始」
/// 才收到一行英文系統錯誤（The user declined TCCs for application...）。
struct OnboardingView: View {
    @ObservedObject var permissions: PermissionsManager
    let onContinue: () -> Void

    var body: some View {
        ZStack {
            Color(nsColor: .windowBackgroundColor).ignoresSafeArea()
            VStack(alignment: .leading, spacing: 28) {
                header

                permissionRow(
                    icon: "display", title: L("Screen & System Audio Recording"),
                    detail: L("Needed to capture system audio from Meet, Teams and the like. You can turn it off again in System Settings whenever you want."),
                    granted: permissions.screenRecordingGranted,
                    onGrant: { permissions.requestScreenRecording() },
                    onOpenSettings: { permissions.openSystemSettings(pane: "Privacy_ScreenCapture") })

                permissionRow(
                    icon: "mic.fill", title: L("Microphone"),
                    detail: L("Only used when you pick the Microphone source; system audio mode doesn't need it."),
                    granted: permissions.microphoneGranted,
                    onGrant: { permissions.requestMicrophone() },
                    onOpenSettings: { permissions.openSystemSettings(pane: "Privacy_Microphone") })

                if permissions.screenRecordingGranted {
                    Text(L("Once both are granted you can start. Change a permission in System Settings and this page updates when you come back."))
                        .font(.caption).foregroundStyle(.secondary)
                } else {
                    Label(L("Without screen recording permission, system audio mode records silence — tick OpenRoom in System Settings, and the first time you also have to restart the app."),
                          systemImage: "info.circle")
                        .font(.caption).foregroundStyle(.orange)
                }

                HStack {
                    Button(L("Skip for now, microphone only"), action: onContinue)
                        .buttonStyle(.plain).foregroundStyle(.secondary).font(.caption)
                    Spacer()
                    Button(L("Continue"), action: onContinue)
                        .buttonStyle(.borderedProminent).controlSize(.large)
                        .disabled(!permissions.screenRecordingGranted && !permissions.microphoneGranted)
                }
            }
            .padding(36)
            .frame(maxWidth: 480)
        }
        .onAppear { permissions.refresh() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            permissions.refresh()
        }
    }

    private var header: some View {
        HStack(spacing: 14) {
            ZStack {
                Circle().fill(Color.accentColor.opacity(0.15)).frame(width: 44, height: 44)
                Image(systemName: "checkmark.shield").font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(Color.accentColor)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(L("Welcome to OpenRoom")).font(.system(size: 22, weight: .bold))
                Text(L("Grant two system permissions first, so recording doesn't die halfway through."))
                    .font(.callout).foregroundStyle(.secondary)
            }
        }
    }

    private func permissionRow(icon: String, title: String, detail: String, granted: Bool,
                                onGrant: @escaping () -> Void, onOpenSettings: @escaping () -> Void) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: icon).font(.system(size: 16, weight: .semibold))
                .foregroundStyle(granted ? Color.accentColor : .secondary)
                .frame(width: 22, height: 22)
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.subheadline.weight(.semibold))
                Text(detail).font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            if granted {
                Label(L("Granted"), systemImage: "checkmark.circle.fill")
                    .font(.caption.weight(.medium)).foregroundStyle(.green)
                    .padding(.horizontal, 10).padding(.vertical, 6)
                    .background(Capsule().fill(Color.green.opacity(0.1)))
            } else {
                Button(L("Grant"), action: onGrant).buttonStyle(.bordered).controlSize(.small)
                Button(L("System Settings"), action: onOpenSettings).buttonStyle(.bordered).controlSize(.small)
            }
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color(nsColor: .controlBackgroundColor)))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color(nsColor: .separatorColor)))
    }
}
