# Feature: Engine

The **orchestrator** — glues all other features together into the full on-screen guidance pipeline:

```
WindowCapture → PanelDetection → OCRScrollAccumulator → SolutionGenerators → GuidanceOverlay
```

This is what the GroundingKit app uses as its main loop. It's the least reusable feature on its own — use it if you want the full pipeline, or study it as a reference for building your own orchestrator.

## What's in this folder

| File | Purpose |
|------|---------|
| `ContentState.swift` | Thread-safe shared state across the cycle: current question text, editor contents, solution lines, typing phase, question-type (coding vs multiple-choice). Coordinates all the features. |
| `PlatformConfig.swift` | Site-specific configuration hooks — sidebar labels, UI keywords, template class patterns, solution generator I/O hints, overlay mode. Default: `generic` platform with empty filters. |

## Standalone use (writing your own orchestrator)

```swift
let state = ContentState()
let detector = NativePanelDetector()
let accumulator = ScrollAccumulator()
let scrollSignal = ScrollSignal()
let overlay = OverlayController()

// 7-cycle loop (simplified)
Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { _ in
    Task {
        guard let image = captureScreenExcluding(windowID: overlay.windowID) else { return }

        // VLM on some cycles only (expensive)
        if shouldRunVLM() {
            if let analysis = await detector.detectPanels(from: image) {
                state.questionBounds = analysis.questionPanel.bounds
                state.editorBounds = analysis.editorPanel.bounds
            }
        }

        // OCR always (cheap)
        let scan = await OCRScanner.scanWithBounds(
            image: image,
            questionBounds: state.questionBounds,
            editorBounds: state.editorBounds
        )
        state.update(from: scan)
        accumulator.ingest(scan.question.lines)

        // Scroll if needed
        scrollSignal.evaluate(scan: scan)
        if scrollSignal.needsScrollDown {
            // emit CGEvent scroll here
        }

        // Solve + render guide
        if state.readyToCallLLM, let solution = await ClaudeSolver.solveCoding(...) {
            state.setSolution(solution)
            overlay.showSolutionOnQuestion(code: solution, questionBounds: state.questionBounds)
        }
    }
}
```

## Dependencies

- **Internal:** all other features:
  - `../WindowCapture/` — screen capture
  - `../PanelDetection/` — panel bboxes
  - `../OCRScrollAccumulator/` — text extraction
  - `../SolutionGenerators/` — LLM backends
  - `../GuidanceOverlay/` — overlay rendering
  - `../ChangeDetection/` — (optional) fast-path change gating

## Public API surface

- `ContentState` — shared state object
- `PlatformConfig` — platform-specific config bundle
- `PlatformConfig.detect()` — auto-detect from frontmost Chrome window title (extend for your sites)

## Notes

- **Platform config** is meant to be extended — add your own site's `PlatformConfig` (sidebar labels to filter, UI keywords to ignore, etc.) and wire `.detect()` to return it based on window title matching.
- **7-cycle rhythm** in the reference app runs VLM sparingly (cycles 1/3/5 in round 1, cycles 1/4 in round 2, cycle 1 thereafter) since VLM is the expensive part. Your orchestrator can use a different rhythm.
- See `Sources/GroundingKitApp/main.swift` for the full reference orchestrator.
