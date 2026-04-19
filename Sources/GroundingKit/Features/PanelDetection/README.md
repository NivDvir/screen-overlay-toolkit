# Feature: PanelDetection

Given a screenshot, detect labeled UI panels (question, editor, output, …) as bounding boxes in logical screen coordinates. Three backends:

1. **NativePanelDetector** — Qwen2.5-VL-7B via MLX Swift. On-device, Apple Silicon only. ~15-30s per inference on M1 Pro, 0px delta vs Python reference (with MROPE fixes applied — see `../../../../BUILD_NOTES.md`).
2. **PythonPanelDetector** — persistent Python subprocess running `mlx-vlm`. More reliable across MLX Swift bugs, ~5s subprocess spawn + 15s inference.
3. **FastPanelDetector** — Vision framework heuristics (no VLM). Fast, less accurate. Useful as a fallback or for simple layouts.

## Standalone use

```swift
// 1. Pick the backend
let detector = NativePanelDetector()  // or PythonPanelDetector() / FastPanelDetector()
try await detector.loadModel()  // NativePanelDetector only — ~3s first time, then instant

// 2. Configure optional platform hints (defaults work for generic)
// (PlatformConfig is in Features/Engine — you can skip it for standalone use)

// 3. Run detection on a screenshot
if let analysis = await detector.detectPanels(from: screenImage) {
    print(analysis.questionPanel.bounds)   // CGRect in logical coords
    print(analysis.editorPanel.bounds)
}
```

## What's in this folder

| File | Purpose |
|------|---------|
| `PanelDetector.swift` | Shared protocol + types (`ScreenAnalysis`, `PanelInfo`) — common surface for all three backends. |
| `NativePanelDetector.swift` | Qwen2.5-VL via MLX Swift (`mlx-swift-lm`). The main detector. |
| `PythonPanelDetector.swift` | Persistent Python subprocess running `panel_detector_server.py`. Alternative backend. |
| `FastPanelDetector.swift` | Vision-framework heuristic detector (bbox via text-layout analysis). Fastest, least accurate. |

## Dependencies

- **External (NativePanelDetector):** `MLXVLM`, `MLXLMCommon`, `Transformers` — Swift package dependencies declared in root `Package.swift`.
- **External (PythonPanelDetector):** Python 3 with `mlx-vlm` and `Pillow` installed. Spawns `python3 panel_detector_server.py`.
- **External (FastPanelDetector):** `Vision` framework (built-in).
- **Internal:** `Features/WindowCapture/ScreenScale.swift` for Retina math.

## Public API surface

- `PanelDetector` protocol
- `ScreenAnalysis` — `{ platform, questionPanel, editorPanel, solution }`
- `PanelInfo` — `{ bounds, title, content, lineHeight, firstLineY }`
- `NativePanelDetector`, `PythonPanelDetector`, `FastPanelDetector` — the three backends

## Tuning notes

- **Image resize:** Qwen2.5-VL was trained at max 1280px longest side. `NativePanelDetector` resizes accordingly. Sending larger images (e.g., 1800px) pushes visual tokens outside the training distribution.
- **Vision attention mask:** The MROPE fixes in our `mlx-swift-lm` fork (commit `b4ea2216`) make windowed attention work correctly — without them, bboxes drift by 200-800px.
- **Prompt engineering:** the default prompt asks for "question" and "editor" panels. Customize `prompt` argument in `detectPanels(from:prompt:)` for other panel types.
- **Chrome clamping:** post-process panel bounds with `ChromeCapture.clampToChrome()` — VLM occasionally returns bboxes that extend into desktop/Finder content when Chrome doesn't fill the screen.
