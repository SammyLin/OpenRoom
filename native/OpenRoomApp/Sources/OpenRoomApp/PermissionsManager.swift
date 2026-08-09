import AVFoundation
import CoreGraphics
import AppKit

/// 兩個 TCC 權限：螢幕錄製（system 音訊要用）、麥克風（mic 音訊要用）。
/// 沒有這頁之前，使用者只會在點「開始」失敗後看到一行英文系統錯誤（見
/// AudioCapture.startSystem 的 catch）——先把「要授權什麼、去哪裡授權」講清楚。
@MainActor
final class PermissionsManager: ObservableObject {
    @Published var screenRecordingGranted = CGPreflightScreenCaptureAccess()
    @Published var microphoneGranted = AVCaptureDevice.authorizationStatus(for: .audio) == .authorized

    func refresh() {
        screenRecordingGranted = CGPreflightScreenCaptureAccess()
        microphoneGranted = AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
    }

    /// 螢幕錄製沒有 callback：使用者在系統設定切完，回 app 前景時 refresh() 才看得到。
    func requestScreenRecording() {
        CGRequestScreenCaptureAccess()
        refresh()
    }

    func requestMicrophone() {
        AVCaptureDevice.requestAccess(for: .audio) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
    }

    func openSystemSettings(pane: String) {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(pane)") else { return }
        NSWorkspace.shared.open(url)
    }
}
