// SPDX-License-Identifier: MIT
//
// Public SDK facade for GroundingKit. The single entry point external Swift
// projects depend on when they want VLM-based screen-region grounding without
// pulling in the full GroundingKitApp shell.
//
// Three-line consumer pattern:
//
//     import GroundingKit
//     let grounder = try await Grounder()
//     let regions = try await grounder.ground(image: cgImage, prompt: "the question panel on the left")

import Foundation
import CoreGraphics

/// VLM-backed image grounder. Wraps Qwen2.5-VL (via mlx-swift-lm) into a
/// minimal async API: load a model once, then call ``ground(image:prompt:)``
/// with arbitrary natural-language prompts to get bounding-box coordinates.
///
/// Marked `@unchecked Sendable` — Grounder's only public methods are async
/// throws, and underlying MLX inference serializes naturally. Callers that
/// need concurrent grounding requests should still wrap a single Grounder
/// instance in their own actor; this conformance just lets it cross
/// isolation boundaries (e.g. into an MCP-server actor).
///
/// The underlying model and patched mlx-swift-lm dependency are documented in
/// the repo README. To use a different model that shares Qwen2.5-VL's
/// architecture (e.g. UI-TARS-1.5-7B), set the `GK_MODEL` environment
/// variable to its `mlx-community/...` slug before constructing the Grounder.
public final class Grounder: @unchecked Sendable {
    private let detector: NativePanelDetector

    /// Loads the underlying VLM. The model weights must be pre-downloaded to
    /// `~/.cache/huggingface/hub/models--<slug>/snapshots/...` (HuggingFace's
    /// standard cache layout). The default model is
    /// `mlx-community/Qwen2.5-VL-7B-Instruct-4bit`; override with the
    /// `GK_MODEL` env var to swap in a Qwen2.5-VL-architecture derivative.
    ///
    /// Cold load takes 25–40 s on first run while MLX compiles Metal kernels;
    /// subsequent loads in the same process are instant.
    ///
    /// - Throws: An error if the model cannot be located in the HuggingFace
    ///   cache, or if `mlx-swift-lm`'s `loadModelContainer` fails.
    public init() async throws {
        self.detector = NativePanelDetector()
        try await detector.loadModel()
    }

    /// Detect bounding-box regions in an image using a free-form prompt.
    ///
    /// Recommended prompt style for Qwen2.5-VL:
    ///
    ///     Detect these N UI regions and output their bbox_2d coordinates
    ///     as a JSON array:
    ///     1. "name1" - description
    ///     2. "name2" - description
    ///
    /// For UI-TARS, the model also accepts the native grounding-token format
    /// (`<|object_ref_start|>...<|box_start|>...<|box_end|>`); the SDK parses
    /// both response formats.
    ///
    /// - Parameters:
    ///   - image: The image to ground. Will be ICC-retagged to sRGB and
    ///     resized to the model's patch grid (max 1280 px longest side,
    ///     snapped to multiples of 28).
    ///   - prompt: Natural-language instruction. Phrasing matters — see
    ///     above for proven patterns.
    /// - Returns: An array of ``BoundingBox`` values in the model's resize
    ///   coordinate space. Scale by `screen.width / 1280` to project back to
    ///   screen pixels.
    /// - Throws: ``NativePanelDetector/DetectionError`` (`.modelNotLoaded` or
    ///   `.noRegionsDetected`).
    public func ground(image: CGImage, prompt: String) async throws -> [BoundingBox] {
        try await detector.detect(from: image, prompt: prompt)
    }

    /// Optional progress callback. Set to receive textual status updates
    /// during model load and inference (e.g. for menu-bar progress UI).
    public var onProgress: ((String) -> Void)? {
        get { detector.onProgress }
        set { detector.onProgress = newValue }
    }
}
