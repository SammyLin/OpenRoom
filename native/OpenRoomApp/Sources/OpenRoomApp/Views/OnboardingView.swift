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
                    icon: "display", title: "螢幕與系統錄音",
                    detail: "抓 Meet／Teams 等系統音訊要用。之後可以隨時在「系統設定」關掉。",
                    granted: permissions.screenRecordingGranted,
                    onGrant: { permissions.requestScreenRecording() },
                    onOpenSettings: { permissions.openSystemSettings(pane: "Privacy_ScreenCapture") })

                permissionRow(
                    icon: "mic.fill", title: "麥克風",
                    detail: "只有選「麥克風」來源時才用得到，系統音訊模式不需要。",
                    granted: permissions.microphoneGranted,
                    onGrant: { permissions.requestMicrophone() },
                    onOpenSettings: { permissions.openSystemSettings(pane: "Privacy_Microphone") })

                if permissions.screenRecordingGranted {
                    Text("授權完成就能開始。切到系統設定改完權限，回來這頁會自動更新。")
                        .font(.caption).foregroundStyle(.secondary)
                } else {
                    Label("螢幕錄製沒授權的話，系統音訊模式收不到聲音——切到「系統設定」勾選 OpenRoom 之後，第一次要重開 app 才會生效。",
                          systemImage: "info.circle")
                        .font(.caption).foregroundStyle(.orange)
                }

                HStack {
                    Button("先跳過，只用麥克風", action: onContinue)
                        .buttonStyle(.plain).foregroundStyle(.secondary).font(.caption)
                    Spacer()
                    Button("繼續", action: onContinue)
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
                Text("歡迎使用 OpenRoom").font(.system(size: 22, weight: .bold))
                Text("先給兩個系統權限，錄音才不會半路失敗。").font(.callout).foregroundStyle(.secondary)
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
                Label("已授權", systemImage: "checkmark.circle.fill")
                    .font(.caption.weight(.medium)).foregroundStyle(.green)
                    .padding(.horizontal, 10).padding(.vertical, 6)
                    .background(Capsule().fill(Color.green.opacity(0.1)))
            } else {
                Button("授權", action: onGrant).buttonStyle(.bordered).controlSize(.small)
                Button("系統設定", action: onOpenSettings).buttonStyle(.bordered).controlSize(.small)
            }
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color(nsColor: .controlBackgroundColor)))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color(nsColor: .separatorColor)))
    }
}
