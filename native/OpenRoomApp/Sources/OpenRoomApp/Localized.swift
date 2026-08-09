import Foundation

/// 翻譯有兩個落腳處，因為這個 target 真的有兩種跑法：
///   - 打包過的 OpenRoom.app：`Contents/Resources/<lang>.lproj`，也就是 Bundle.main。
///     資源包不能放在 .app 根目錄（`codesign --deep` 會抱怨 unsealed contents），所以
///     SPM 產的 `OpenRoomApp_OpenRoomApp.bundle` 在這裡用不上。
///   - 直接跑 `.build/release/OpenRoomApp`：SPM 的 Bundle.module。
/// 兩邊都查不到時 Bundle.module 會直接 fatalError——沒有「靜靜地把 key 當文案畫出來」
/// 這條路，那正是這專案第一守則禁止的靜默降級。
private let stringsBundle: Bundle =
    Bundle.main.url(forResource: "en", withExtension: "lproj") != nil ? .main : .module

/// key 就是英文原文：某個語言漏翻只會退回正確的英文，不會退回 `setup.title` 這種鬼東西。
/// view 裡一律傳 L() 的結果（String，不是 LocalizedStringKey），SwiftUI 才不會再翻一次。
func L(_ key: String) -> String {
    NSLocalizedString(key, bundle: stringsBundle, comment: "")
}
