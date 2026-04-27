// swift-tools-version: 6.0
//
// Standalone SPM package for the SDK probe binary.
// Pinned to the parent screen-overlay-toolkit at the same commit so the
// Grounder behavior we test matches the Grounder we ship.

import PackageDescription

let package = Package(
    name: "SDKProbe",
    platforms: [.macOS(.v15)],
    products: [
        .executable(name: "SDKProbe", targets: ["SDKProbe"]),
    ],
    dependencies: [
        // During cross_adapter_gate.sh setup, this is rewritten to point at
        // the parent repo at $REPO_ROOT (the running checkout).
        .package(name: "screen-overlay-toolkit", path: "../../.."),
    ],
    targets: [
        .executableTarget(
            name: "SDKProbe",
            dependencies: [
                .product(name: "GroundingKit", package: "screen-overlay-toolkit"),
            ],
            path: ".",
            sources: ["SDKProbe.swift"]
        ),
    ]
)
