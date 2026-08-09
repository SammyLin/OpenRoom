// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "OpenRoomApp",
    platforms: [.macOS(.v13)],
    targets: [
        .executableTarget(name: "OpenRoomApp", path: "Sources/OpenRoomApp")
    ]
)
