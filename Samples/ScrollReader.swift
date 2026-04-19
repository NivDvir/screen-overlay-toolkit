// Sample: ScrollReader
//
// Read text out of a scrollable region on screen — even when content exceeds the viewport.
// Use case: automation scripts that need to "read everything" in a chat window / long article /
// terms-of-service dialog / settings panel / release notes — anywhere the useful content
// is longer than one viewport.
//
// Pipeline:
//   1. OCR the visible region (Apple Vision)
//   2. ScrollSignal determines if there's more below
//   3. If yes: send a CGEvent scroll, wait, OCR again, fuzzy-stitch via ScrollAccumulator
//   4. Repeat until content stops changing
//
// To run this sample:
//   1. Copy Sources/GroundingKit/Features/OCRScrollAccumulator/ + WindowCapture/ into your project.
//   2. Copy this file.
//   3. `swift run` — grant Screen Recording + Accessibility permissions on first run.
//
// This file is NOT included in the main GroundingKit build. It's a copy-paste seed.

import AppKit
import CoreGraphics

@main
struct ScrollReader {
    static func main() async throws {
        // Configure the region to read — customize to your target
        let targetBounds = CGRect(x: 100, y: 200, width: 700, height: 500)

        // Mouse coords to scroll at (inside the target region)
        let scrollX = targetBounds.midX
        let scrollY = targetBounds.midY

        let accumulator = ScrollAccumulator()
        let scrollSignal = ScrollSignal()

        for attempt in 0..<10 {
            // 1. Screenshot
            guard let image = CGWindowListCreateImage(
                .infinite,
                .optionOnScreenOnly,
                kCGNullWindowID,
                [.bestResolution]
            ) else { continue }

            // 2. OCR the target bounds
            let scan = await OCRScanner.scanWithBounds(
                image: image,
                questionBounds: targetBounds,
                editorBounds: .zero
            )

            // 3. Ingest into accumulator (dedupes across scrolls via fuzzy matching)
            accumulator.ingest(scan.question.lines)

            // 4. Check if more content is below the fold
            scrollSignal.evaluate(scan: scan)
            if !scrollSignal.needsScrollDown {
                print("✓ No more content below after \(attempt + 1) iterations")
                break
            }

            // 5. Scroll the target region (CGEvent scroll events)
            if let moveEvent = CGEvent(mouseEventSource: nil,
                                       mouseType: .mouseMoved,
                                       mouseCursorPosition: CGPoint(x: scrollX, y: scrollY),
                                       mouseButton: .left) {
                moveEvent.post(tap: .cghidEventTap)
            }
            if let scrollEvent = CGEvent(scrollWheelEvent2Source: nil,
                                         units: .pixel,
                                         wheelCount: 1,
                                         wheel1: -120,  // scroll down
                                         wheel2: 0,
                                         wheel3: 0) {
                scrollEvent.post(tap: .cghidEventTap)
            }

            // 6. Wait for scroll to settle
            try await Task.sleep(nanoseconds: 500_000_000)
        }

        // Final transcript
        print("=== Accumulated text ===")
        print(accumulator.fullText)
        print("=== \(accumulator.lineCount) lines ===")
    }
}
