// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "huddle-diarize",
    platforms: [.macOS(.v14)],  // FluidAudio 要求 macOS 14+
    dependencies: [
        .package(url: "https://github.com/FluidInference/FluidAudio.git", from: "0.15.0")
    ],
    targets: [
        .executableTarget(
            name: "huddle-diarize",
            dependencies: [.product(name: "FluidAudio", package: "FluidAudio")],
            path: "Sources/huddle-diarize"
        )
    ]
)
