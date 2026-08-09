import SwiftUI
import Sparkle

/// 更新是「從網路上抓程式碼下來執行」，所以只有一個判準：能不能驗簽章。
/// SUPublicEDKey 是 Sparkle 驗 EdDSA 簽章用的公鑰，build-app.sh 只在維護者
/// 有給金鑰時才寫進 Info.plist。沒有這把鑰匙的 build 就是不能更新——
/// 這裡直接不啟動 updater，而不是啟動一個驗不了簽章的 updater。
/// 沒有 fallback、沒有「先裝再說」的旗標：那條路的終點是每個使用者都被裝進東西。
private let updaterController: SPUStandardUpdaterController? = {
    let key = (Bundle.main.object(forInfoDictionaryKey: "SUPublicEDKey") as? String)?
        .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    guard !key.isEmpty else {
        FileHandle.standardError.write(Data("openroom: no SUPublicEDKey in Info.plist — auto-update disabled\n".utf8))
        return nil
    }
    return SPUStandardUpdaterController(startingUpdater: true, updaterDelegate: nil, userDriverDelegate: nil)
}()

@main
struct OpenRoomApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
        }
        .windowResizability(.contentSize)
        .commands {
            CommandGroup(after: .appInfo) {
                if let updater = updaterController {
                    Button(L("Check for Updates…")) { updater.checkForUpdates(nil) }
                } else {
                    // 灰掉但寫實話。一個按了沒反應的「檢查更新」就是靜默降級。
                    Button(L("Updates unavailable — this build has no update key")) {}
                        .disabled(true)
                }
            }
        }
    }
}
