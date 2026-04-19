# Feature: GuidanceOverlay

Draw arbitrary markers, ghost text, arrows, and status bars on top of the screen via a borderless `NSWindow` that covers the full display. The overlay window ignores mouse events so the underlying UI stays interactive.

## Standalone use

Copy this folder (plus `../ChangeDetection/PixelDiff.swift` if you want change-gated rendering) into any macOS 14+ Swift project.

```swift
import AppKit

// 1. Create the overlay (covers the main screen)
let overlay = OverlayController()

// 2. Status bar at screen-center
overlay.setStatus("Detecting panels…")

// 3. Colored panel boxes
overlay.showPanel(
    PanelRect(x: 100, y: 200, w: 600, h: 400),
    color: "green",
    label: "question"
)
overlay.showPanel(
    PanelRect(x: 750, y: 200, w: 600, h: 400),
    color: "red",
    label: "editor"
)

// 4. Ghost text (hints drawn in editor-colored text at specific coords)
overlay.showTextBlocks([
    TextBlock(text: "class Solution {", x: 800, y: 250, color: "gray50"),
    TextBlock(text: "  public int solve()…", x: 800, y: 280, color: "gray70"),
])
```

Coordinates are in **logical (non-Retina) screen space, top-left origin** — same coordinate system as `CGWindowListCreateImage` with `NSScreen.main.frame`.

## What's in this folder

| File | Purpose |
|------|---------|
| `OverlayController.swift` | Wraps the borderless `NSWindow` (level 25, transparent, non-interactive). Public API for status, panels, and text blocks. |
| `GhostLayout.swift` | Positions ghost text inside an editor panel based on line heights and UI keyword filtering. |

## Dependencies

- **None external** — uses only `AppKit` + `Foundation` + `CoreGraphics`.
- **Internal (within GroundingKit):** none. Fully self-contained.

## Public API surface

- `OverlayController` — the main entry; owns the overlay window and view model
- `PanelRect` — `(x, y, w, h)` struct for panel bounds
- `TextBlock` — `(text, x, y, color)` struct for ghost text
- `StatusSegment` — `(text, color)` for multi-colored status bar
- `GhostLayout` — static utility for generating ghost-text positions given a panel and solution lines

## Notes

- `NSWindow(level: 25)` reliably renders above Chrome and other normal windows on macOS 14+. Levels 20-24 can be covered by some status bar items.
- `sharingType = .none` hides the overlay from `CGWindowListCreateImage` — so the overlay's own content doesn't pollute the next detection cycle's screenshot.
- The `contentProtected: true` flag (not set by default in GroundingKit) hides the overlay from `ScreenCaptureKit` as well — useful for anti-screenshot scenarios.
