// Sample: MinimalPanelDetection
//
// Detect labeled panels in a screenshot using the PanelDetection feature.
// Use case: any tool that needs to know "where are the UI panels on this screen" —
// screenshot annotation tools, accessibility overlays, automated testing, UX analysis.
//
// Uses Qwen2.5-VL-7B via MLX Swift. Requires Apple Silicon + ~6GB RAM for the model.
//
// To run this sample:
//   1. Copy Sources/GroundingKit/Features/PanelDetection/ + WindowCapture/ into your project.
//   2. Add mlx-swift-lm + swift-transformers SPM dependencies (see root Package.swift).
//      IMPORTANT: use the NivDvir/mlx-swift-lm fork or apply the MROPE patch for correct bbox output.
//   3. Copy this file.
//   4. `swift run` — grant Screen Recording permission on first run.
//
// This file is NOT included in the main GroundingKit build. It's a copy-paste seed.

import AppKit
import CoreGraphics

@main
struct MinimalPanelDetection {
    static func main() async throws {
        // 1. Load the VLM (one-time, ~3s after model weights are cached)
        let detector = NativePanelDetector()
        try await detector.loadModel()
        print("✓ VLM loaded")

        // 2. Capture the screen
        guard let image = CGWindowListCreateImage(
            .infinite,
            .optionOnScreenOnly,
            kCGNullWindowID,
            [.bestResolution]
        ) else {
            fatalError("Screen capture failed — grant Screen Recording permission")
        }
        print("✓ Captured screen at \(image.width)x\(image.height)")

        // 3. Run detection
        guard let analysis = await detector.detectPanels(from: image) else {
            print("✗ No panels detected")
            return
        }

        print("✓ Detected panels:")
        print("  question: \(analysis.questionPanel.bounds)")
        print("  editor:   \(analysis.editorPanel.bounds)")
        print("  platform: \(analysis.platform)")

        // 4. (Optional) clamp bbox results to Chrome if detection is Chrome-scoped
        let chromeClampedQ = ChromeCapture.clampToChrome(analysis.questionPanel.bounds)
        let chromeClampedE = ChromeCapture.clampToChrome(analysis.editorPanel.bounds)
        if chromeClampedQ != analysis.questionPanel.bounds {
            print("  (question clamped to Chrome: \(chromeClampedQ))")
        }
        if chromeClampedE != analysis.editorPanel.bounds {
            print("  (editor clamped to Chrome: \(chromeClampedE))")
        }

        // 5. Use the bounds for whatever your tool needs:
        //    - crop that region from the screenshot
        //    - draw an overlay around it
        //    - OCR just that area
        //    - pass to another ML model
        //    - record it for usage analytics
    }
}
