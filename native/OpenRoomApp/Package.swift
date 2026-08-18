// swift-tools-version:5.9
import PackageDescription

// defaultLocalization 是 en：英文是開發語言，也是漏翻時的 fallback。
let package = Package(
    name: "OpenRoomApp",
    defaultLocalization: "en",
    // v14 是 mlx-audio-swift 的下限，不是我們的選擇。
    platforms: [.macOS(.v14)],
    dependencies: [
        // macOS 沒有 App Store 以外的內建更新機制，自己寫等於自己寫簽章驗證——
        // 那正是這種東西出事的方式。用 Sparkle 2，鎖同一個 major。
        .package(url: "https://github.com/sparkle-project/Sparkle", .upToNextMajor(from: "2.6.0")),
        // ASR / diarization：取代 Python 的 mlx-qwen3-asr + pyannote。
        // 這個 package 沒有正式 release，只能釘 commit——釘 branch 等於每次 build
        // 都可能換一套 API。
        .package(url: "https://github.com/Blaizzy/mlx-audio-swift.git", branch: "main"),
        // Sortformer 的 API 收 MLXArray，所以這個要直接相依，不能只靠傳遞相依。
        .package(url: "https://github.com/ml-explore/mlx-swift.git", .upToNextMajor(from: "0.30.6")),
        // 模型下載要有進度：mlx-audio 的 `fromPretrained` 不收 progressHandler，但它底下的
        // `ModelUtils.resolveOrDownloadModel` 收，那個要 HubClient。版本條件跟
        // mlx-audio-swift 宣告的一樣，不然 resolve 會撞車。
        .package(url: "https://github.com/huggingface/swift-huggingface.git", .upToNextMajor(from: "0.8.1"))
    ],
    targets: [
        .executableTarget(
            name: "OpenRoomApp",
            dependencies: [
                .product(name: "Sparkle", package: "Sparkle"),
                .product(name: "MLXAudioSTT", package: "mlx-audio-swift"),
                .product(name: "MLXAudioVAD", package: "mlx-audio-swift"),
                .product(name: "MLX", package: "mlx-swift"),
                .product(name: "MLXAudioCore", package: "mlx-audio-swift"),
                .product(name: "HuggingFace", package: "swift-huggingface")
            ],
            path: "Sources/OpenRoomApp",
            resources: [.process("Resources")]
        )
    ]
)
