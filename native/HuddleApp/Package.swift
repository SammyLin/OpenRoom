// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "HuddleApp",
    platforms: [.macOS(.v13)],
    targets: [
        .executableTarget(name: "HuddleApp", path: "Sources/HuddleApp")
    ]
)
