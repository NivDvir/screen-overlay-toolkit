// Sample: ScreenAnnotator
//
// Draw guidance markers on top of the screen using only the GuidanceOverlay feature.
// Use case: build your own on-screen tutorial, debug overlay, click-target highlighter,
// annotation tool, etc. — without any VLM or OCR.
//
// To run this sample:
//   1. Copy Sources/GroundingKit/Features/GuidanceOverlay/ into your project.
//   2. Copy this file too.
//   3. `swift run` (or wrap in a Package.swift as a macOS executable target).
//
// This file is NOT included in the main GroundingKit build. It's a copy-paste seed.

import AppKit

@main
struct ScreenAnnotator {
    static func main() {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)

        let overlay = OverlayController()

        // Draw a colored bounding box around the top-left quadrant
        overlay.showPanel(
            PanelRect(x: 50, y: 50, w: 600, h: 400),
            color: "green",
            label: "demo panel"
        )

        // Draw ghost text anchored at specific screen coords
        overlay.showTextBlocks([
            TextBlock(text: "→ Click the green box to trigger something", x: 670, y: 240, color: "yellow"),
        ])

        // Status bar at screen-center
        overlay.setStatus("ScreenAnnotator demo — press Cmd+Q to quit")

        // Run the app loop — overlay persists until quit
        app.run()
    }
}
