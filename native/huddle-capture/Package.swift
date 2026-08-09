// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "huddle-capture",
    platforms: [.macOS(.v13)],
    targets: [
        .executableTarget(name: "huddle-capture", path: "Sources/huddle-capture")
    ]
)
