// swift-tools-version: 5.9
import PackageDescription

// GroundingKit — feature-organized Swift codebase for on-screen guidance on macOS.
//
// Directory layout (Sources/):
//   • Sources/GroundingKit/Features/<Feature>/  — reusable feature modules
//   • Sources/GroundingKitApp/                    — the macOS menu-bar app (reference consumer)
//
// Each feature folder is self-contained: copy it out with its README to use
// standalone in another project.
//
// Phase 2 (next milestone) will split this into a proper library + executable
// pair with public API boundaries. For now it's a single executable target
// with feature-organized folders.

let package = Package(
    name: "GroundingKit",
    platforms: [.macOS(.v14)],
    dependencies: [
        // Pin to NivDvir's fork with MROPE fixes for Qwen2.5-VL (subject of dev.to publication).
        // Upstream ml-explore/mlx-swift-lm@8c9dd63 lacks these fixes. Fork commit b4ea2216
        // "Fix Qwen2.5-VL MROPE implementation — 7 bugs". PR tracking: ml-explore/mlx-swift-lm#222.
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
