// swift-tools-version:5.9
import PackageDescription

// defaultLocalization 是 en：英文是開發語言，也是漏翻時的 fallback。
let package = Package(
    name: "OpenRoomApp",
    defaultLocalization: "en",
    platforms: [.macOS(.v13)],
    dependencies: [
        // macOS 沒有 App Store 以外的內建更新機制，自己寫等於自己寫簽章驗證——
        // 那正是這種東西出事的方式。用 Sparkle 2，鎖同一個 major。
        .package(url: "https://github.com/sparkle-project/Sparkle", .upToNextMajor(from: "2.6.0"))
    ],
    targets: [
        .executableTarget(
            name: "OpenRoomApp",
            dependencies: [.product(name: "Sparkle", package: "Sparkle")],
            path: "Sources/OpenRoomApp",
            resources: [.process("Resources")]
        )
    ]
)
