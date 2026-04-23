# Feature: WindowCapture

Capture the full screen, a specific region, or a specific app's window (e.g. Chrome). Provides coordinate helpers for Retina scaling and bounds detection.

## Standalone use

```swift
// 1. Find Chrome window matching platform-specific keywords
ChromeCapture.windowKeywords = ["Wikipedia", "arXiv"]
let chromeBounds = ChromeCapture.chromeBounds()  // CGRect in logical coords, .zero if not found

// 2. Capture just the Chrome window
if let chromeImage = ChromeCapture.captureChrome() {
    // chromeImage is a CGImage — full Chrome window, no other windows composited
}

// 3. Or capture the full screen, excluding the overlay window
if let screenImage = CGWindowListCreateImage(
    CGRect.infinite,
    .optionOnScreenBelowWindow,
    overlayWindowID,
    [.bestResolution]
) {
    // screenImage at Retina resolution
    let retinaScale = ScreenScale.factor  // typically 2.0
}

// 4. Clamp a VLM-detected bbox to Chrome window bounds (useful post-processing)
let rawPanelBounds = CGRect(x: 100, y: 200, width: 800, height: 600)
let clampedBounds = ChromeCapture.clampToChrome(rawPanelBounds)
```

## What's in this folder

| File | Purpose |
|------|---------|
| `ScreenCapture.swift` | Timer-driven main capture loop (used by the app's cycle). Also has filter-line skip list (common UI chrome to ignore). |
| `ChromeCapture.swift` | Find and capture Chrome (or Chromium) windows, clamp arbitrary rects to Chrome bounds. |
| `ScreenScale.swift` | `ScreenScale.factor` — dynamic Retina scale detection (2.0 on Retina, 1.0 on non-Retina). |

## Dependencies

- **External:** `AppKit`, `CoreGraphics` (built-in).
- **Internal:** none.

## Public API surface

- `ChromeCapture.windowKeywords: [String]` — optional filter list
- `ChromeCapture.findChromeWindowID() -> CGWindowID?`
- `ChromeCapture.chromeBounds() -> CGRect` — logical coords
- `ChromeCapture.clampToChrome(_: CGRect) -> CGRect`
- `ChromeCapture.captureChrome() -> CGImage?`
- `ScreenScale.factor: CGFloat`

## Notes

- `CGWindowListCreateImage` is deprecated on macOS 14+ but still works and is the fastest path. `ScreenCaptureKit` is the modern replacement — drop-in if you need long-term stability.
- All coordinates are **logical (non-Retina)** unless captured images are noted otherwise.
- For apps that aren't Chrome, add your target's window owner name to the owner check in `findChromeWindowID` (or fork this module for a generic WindowCapture).
