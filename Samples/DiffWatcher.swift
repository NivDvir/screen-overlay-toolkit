// Sample: DiffWatcher
//
// Watch a screen region for changes using only the ChangeDetection feature.
// Use case: a "wait until UI updates" primitive for automation scripts — detect
// when a chart refreshes, when a notification appears, when a text field finishes loading, etc.
//
// To run this sample:
//   1. Copy Sources/GroundingKit/Features/ChangeDetection/PixelDiff.swift into your project.
//   2. Copy this file.
//   3. `swift run` with macOS 14+ SDK.
//
// This file is NOT included in the main GroundingKit build. It's a copy-paste seed.

import AppKit
import CoreGraphics

@main
struct DiffWatcher {
    static func main() {
        // Watch this region for changes — customize to your target coords
        let watchRegion = CGRect(x: 100, y: 100, width: 800, height: 600)

        let differ = PixelDiff()
        guard let initial = CGWindowListCreateImage(.infinite, .optionOnScreenOnly, kCGNullWindowID, [.bestResolution]) else {
            fatalError("Screen capture failed — grant Screen Recording permission")
        }
        differ.capture(region: watchRegion, from: initial)

        print("Watching region \(watchRegion)... change something on screen")

        // Poll every 100ms — adjust to taste
        Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { _ in
            guard let now = CGWindowListCreateImage(.infinite, .optionOnScreenOnly, kCGNullWindowID, [.bestResolution]) else {
                return
            }
            let state = differ.compare(region: watchRegion, from: now)
            switch state {
            case .identical:
                break  // no output — quiet
            case .minorShift:
                print("[\(Date())] minor shift (cursor blink / scroll?)")
            case .changed:
                print("[\(Date())] REGION CHANGED — trigger your handler here")
                // e.g., take screenshot, OCR, make decision, etc.
            }
        }

        RunLoop.main.run()
    }
}
