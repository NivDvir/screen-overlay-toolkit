// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "GroundingKit",
    platforms: [.macOS(.v14)],
    dependencies: [
        // Pin to NivDvir's fork with MROPE fixes for Qwen2.5-VL (subject of dev.to publication).
        // Upstream ml-explore/mlx-swift-lm pinned at 8c9dd63 lacks these fixes; see fork commit
        // b4ea2216 "Fix Qwen2.5-VL MROPE implementation — 9 bugs". PR tracking upstream issue #221.
        .package(url: "https://github.com/NivDvir/mlx-swift-lm", revision: "b4ea2216f2db5afcb60b325a5f7582c5a1c289bc"),
        .package(url: "https://github.com/huggingface/swift-transformers", from: "0.1.12"),
    ],
    targets: [
        .executableTarget(
            name: "GroundingKit",
            dependencies: [
                .product(name: "MLXVLM", package: "mlx-swift-lm"),
                .product(name: "MLXLMCommon", package: "mlx-swift-lm"),
                .product(name: "Transformers", package: "swift-transformers"),
            ],
            path: "Sources"
        )
    ]
)
