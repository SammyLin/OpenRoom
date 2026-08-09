// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "openroom-capture",
    platforms: [.macOS(.v13)],
    targets: [
        .executableTarget(name: "openroom-capture", path: "Sources/openroom-capture")
    ]
)
