// swift-tools-version:5.9
import PackageDescription

// defaultLocalization 是 en：英文是開發語言，也是漏翻時的 fallback。
let package = Package(
    name: "OpenRoomApp",
    defaultLocalization: "en",
    platforms: [.macOS(.v13)],
    targets: [
        .executableTarget(
            name: "OpenRoomApp",
            path: "Sources/OpenRoomApp",
            resources: [.process("Resources")]
        )
    ]
)
