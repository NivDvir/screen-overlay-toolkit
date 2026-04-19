# Samples

Standalone example snippets showing how to use each GroundingKit feature in isolation — without pulling the full guidance pipeline. Each sample is a minimal, real-world wiring that demonstrates the feature's core capability.

**Not built by default.** These are reference snippets; copy the relevant sample (plus the feature's `Sources/GroundingKit/Features/<FeatureName>/` folder) into your own Swift project.

| Sample | Demonstrates | Copy-in cost |
|---|---|---|
| [`MinimalPanelDetection.swift`](MinimalPanelDetection.swift) | Detect 2 panels in a screenshot, print their bounds | 1 feature folder + ~3 MLX SPM deps |
| [`ScrollReader.swift`](ScrollReader.swift) | OCR a panel, scroll with CGEvent, stitch new text | 1 feature folder + Vision framework |
| [`ScreenAnnotator.swift`](ScreenAnnotator.swift) | Draw markers on screen with no other engine features | 1 feature folder, zero deps |
| [`DiffWatcher.swift`](DiffWatcher.swift) | Detect when a screen region changes | 1 feature folder, zero deps |

Each sample also includes instructions for running it as a standalone Swift executable.
