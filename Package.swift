// swift-tools-version: 5.9
import PackageDescription

// GroundingKit — feature-organized Swift codebase for on-screen guidance on macOS.
//
// Two targets:
//   • GroundingKit     — library. Depend on this from other Swift projects to
//                        reuse the panel detection + OCR + overlay engine.
//   • GroundingKitApp  — reference menu-bar app that consumes the library.
//
// Layout:
//   Sources/GroundingKit/Features/<Feature>/  — public library modules
//   Sources/GroundingKit/TestSupport/          — standalone diagnostics (not shipped)
//   Sources/GroundingKitApp/                   — macOS menu-bar app

let package = Package(
    name: "GroundingKit",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "GroundingKit", targets: ["GroundingKit"]),
        .executable(name: "GroundingKitApp", targets: ["GroundingKitApp"]),
    ],
    dependencies: [
        // Pin to NivDvir's fork with MROPE fixes for Qwen2.5-VL (subject of dev.to publication).
        // Upstream ml-explore/mlx-swift-lm@8c9dd63 lacks these fixes. Pinned at 4edc802 —
        // PR #222 head including the Lanczos preprocessing fix. Earlier cleanup commit
        // (201ca7c) swapped PIL-subprocess Lanczos for CGContext high-quality interpolation,
        // and 310ef13 swapped that for MediaProcessing.resampleBicubic — both regressed
        // inference because they aren't equivalent to PIL.Image.LANCZOS. 4edc802 routes
        // through MediaProcessing.resampleLanczos, which does match PIL and restores 0 px
        // parity with the Python reference on a 2-panel LeetCode test (2026-04-21).
        // PR #222: https://github.com/ml-explore/mlx-swift-lm/pull/222
        .package(url: "https://github.com/NivDvir/mlx-swift-lm", revision: "a3fda9c97319bce4b8ac57f1549a0906801da5b8"),
        .package(url: "https://github.com/huggingface/swift-transformers", from: "0.1.12"),
    ],
    targets: [
        .target(
            name: "GroundingKit",
            dependencies: [
                .product(name: "MLXVLM", package: "mlx-swift-lm"),
                .product(name: "MLXLMCommon", package: "mlx-swift-lm"),
                .product(name: "Transformers", package: "swift-transformers"),
            ],
            path: "Sources/GroundingKit",
            exclude: ["TestSupport"]
        ),
        .executableTarget(
            name: "GroundingKitApp",
            dependencies: ["GroundingKit"],
            path: "Sources/GroundingKitApp"
        ),
    ]
)
