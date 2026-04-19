# GroundingKit

**A real-time, on-screen guidance engine for macOS — native Swift, Apple Silicon, fully local.**

GroundingKit watches what's on your screen, understands the layout, and draws live overlay markers that tell *someone* (a person, or an automation like the included reference consumer) what to do next. Scroll here. Type this line here. The result of the next step should look like this.

It's the "pointing" layer of screen automation — one level below *"describe the screen"* (captioning / Q&A) and one level above *"control the mouse"* (raw input injection). GroundingKit's job is to render actionable visual signals **on** the screen, keyed to what's actually there.

[![Dev.to writeup](https://img.shields.io/badge/writeup-dev.to-black)][writeup] [![Upstream PR](https://img.shields.io/badge/upstream-mlx--swift--lm%23222-blue)][upstream-pr] [![License: MIT](https://img.shields.io/badge/license-MIT-green)](LICENSE)

---

## What it does (and doesn't)

**Does:**
- Detects UI panels (question, editor, output, …) from a full-screen capture via Qwen2.5-VL — on-device, no cloud.
- Runs Apple Vision OCR inside those panels with scroll-accumulation (stitches text that spans multiple scroll positions via fuzzy matching).
- Renders an overlay on top of the screen with guide markers — arrows, annotations, ghost text — aligned to panel coordinates.
- Exposes its "understanding" as files in `/tmp/` so external tools (or a human) can act on it.

**Does not:**
- Solve the problem for you. GroundingKit points *at* things; it doesn't click or type on your behalf. For that, pair it with a consumer — the included [HumanPlayer](#reference-consumer-humanplayer) shows one such pattern.
- Work on non-Apple-Silicon Macs. The VLM runs on MLX/Metal. macOS 14+ on M-series only.
- Replace cloud VLMs. It's optimized for *local*, *interactive-latency* tasks on one screen.

---

## Architecture

```
┌─────────────────────────────────────────────────────────────────────────┐
│  GroundingKit (this repo)                                                │
│  ────────────────────────────────────────────────────────────            │
│                                                                          │
│  ScreenCapture ──► NativePanelDetector ──► DeepScan OCR                  │
│   (CGWindowList)    (Qwen2.5-VL via MLX)    (Apple Vision)               │
│                                │                    │                    │
│                                ▼                    ▼                    │
│                        ScrollAccumulator ◄──► ContentState               │
│                          (text stitching)    (question/editor state)     │
│                                                     │                    │
│                                                     ▼                    │
│                                           OverlayController              │
│                                         (guide markers on screen)        │
└───────────────────────────────────────────────────────┼──────────────────┘
                                                        │
                          guide frame at /tmp/ccsv_overlay_frame.png
                          solution lines at /tmp/ccsv_solution_lines.txt
                                                        │
                                                        ▼
                                        ┌───────────────────────────────┐
                                        │  HumanPlayer (optional)       │
                                        │  reads the guide, acts on it  │
                                        └───────────────────────────────┘
```

The **guide**, not the **consumer**, is the product. GroundingKit's overlay is designed to be actionable by either a human watching the screen or an automated agent (like the included HumanPlayer reference).

---

## Quick start

### Requirements

- macOS 14 or later, **Apple Silicon** (M1/M2/M3/M4)
- Xcode 16+ (Xcode 26 recommended — tested configuration)
- ~6 GB disk for the Qwen2.5-VL-7B-4bit model weights (auto-downloaded on first run)
- ~8 GB free RAM during inference

### Build & run

```bash
git clone https://github.com/NivDvir/screen-overlay-toolkit.git
cd screen-overlay-toolkit
bash build-app.sh
open GroundingKit.app
```

On first launch macOS will prompt for:

- **Screen Recording** (System Settings → Privacy & Security → Screen Recording → add `GroundingKit.app`)
- **Accessibility** (System Settings → Privacy & Security → Accessibility → add `GroundingKit.app`) — needed for auto-scroll events

Once permissions are granted, GroundingKit starts watching your frontmost Chrome window. Open any coding practice site (LeetCode, HackerRank, etc.), and the overlay will appear with detected panel outlines.

### Reference consumer (HumanPlayer)

`HumanPlayer` (in `~/dev/ccsv/plugin/tools/human-player/` — linked here as a submodule or external repo) demonstrates how an agent can act on GroundingKit's guide signals. It:

- Reads `/tmp/ccsv_solution_lines.txt` (solution written by GroundingKit after it thinks about the problem)
- Reads `/tmp/ccsv_overlay_frame.png` and OCRs the overlay for scroll/typing cues
- Types into the editor via CGEvent keyboard events

You can use this to make a demo GIF, or adapt the pattern for your own consumers.

---

## Under the hood — native Swift Qwen2.5-VL

GroundingKit runs Qwen2.5-VL-7B-Instruct-4bit natively on Apple Silicon via [MLX](https://github.com/ml-explore/mlx). **Zero Python in the inference path.**

Getting there required fixing 7 bugs in `mlx-swift-lm`'s Qwen2.5-VL implementation — ranging from a silently-dropped attention mask in the vision encoder (the biggest one) to MROPE section layout, `rope_deltas` not applied during autoregressive generation, and training-distribution mismatches in image resizing. After the fixes, Swift output matches the Python `mlx-vlm` reference at 0px delta on all 8 bounding box edges.

The fixes live on a fork of `mlx-swift-lm` pinned via `Package.swift`:

- **Fork branch:** https://github.com/NivDvir/mlx-swift-lm/tree/fix/qwen25vl-mrope
- **Upstream PR:** [ml-explore/mlx-swift-lm#222][upstream-pr]
- **Full investigation writeup:** [*Building a Real-Time Screen Reader on macOS That Actually Works*][writeup]

The patterns in those fixes likely apply to other MLXVLM models (Qwen2VL, Qwen3VL, GlmOcr, Qwen35) too. Follow-up PRs are planned once #222 settles.

If `#222` gets merged upstream, `Package.swift` will be repointed to `ml-explore/mlx-swift-lm` and the fork retired. Until then, the fork is the ground truth for working Qwen2.5-VL-in-Swift.

---

## File layout

Organized by **feature**, not by layer. Each folder under `Sources/GroundingKit/Features/` is self-contained — copy just that folder into another project to reuse the capability.

```
GroundingKit-axvs-clone/
├── README.md                 # this file
├── BUILD_NOTES.md            # mlx-swift-lm fork dependency notes
├── Package.swift             # SPM config (points at NivDvir/mlx-swift-lm fork)
├── Info.plist                # .app bundle metadata template
├── build-app.sh              # builds GroundingKit.app
├── Sources/
│   ├── GroundingKit/Features/       # ← library code, feature-organized
│   │   ├── WindowCapture/           # find + capture browser windows (+ README)
│   │   ├── PanelDetection/          # Qwen2.5-VL grounding (+ README)
│   │   ├── OCRScrollAccumulator/    # Vision OCR + scroll-stitching (+ README)
│   │   ├── GuidanceOverlay/         # draw markers on screen (+ README)
│   │   ├── SolutionGenerators/      # Claude CLI, Gemini wrappers (+ README)
│   │   ├── ChangeDetection/         # pixel-diff change detection (+ README)
│   │   └── Engine/                  # orchestrator + shared state (+ README)
│   └── GroundingKitApp/             # the shipped macOS app = reference consumer
│       ├── main.swift
│       └── AppDelegate.swift
├── Samples/                         # standalone seed code per feature
│   ├── MinimalPanelDetection.swift
│   ├── ScrollReader.swift
│   ├── ScreenAnnotator.swift
│   └── DiffWatcher.swift
├── Python/                          # optional Python backends (panel_detector*.py)
└── patches/                         # MROPE patch (backup — fork already applies it)
```

Each `Sources/GroundingKit/Features/<Name>/README.md` documents:

- what the feature does
- standalone usage code
- exact cross-feature dependencies
- public API surface

The `Samples/*.swift` files are copy-paste seeds for other projects — minimal real-world wirings using just one feature.

---

## Adapting to your site

Out of the box, GroundingKit works on any Chrome window with no filters. To target a specific site with custom panel detection rules (sidebar labels to ignore, UI keywords to filter, template class patterns), add a case to `PlatformConfig.swift`:

```swift
static let mySite = PlatformConfig(
    name: "MySite",
    browserWindowKeywords: ["MySite", "my-site.io"],
    sidebarLabels: ["forum", "solutions", "discussions"],
    uiKeywords: ["Run", "Submit", "Reset"],
    editorThemeIsDark: true,
    templateClassPatterns: ["class Solution"],
    promptIOHint: "",
    overlayMode: OverlayModeConfig(coverQuestion: true, stepAdvancement: false)
)
```

Then extend `PlatformConfig.detect()` to return `.mySite` when the Chrome window title matches.

---

## License

MIT — see [LICENSE](LICENSE).

---

## Credits

- **Qwen2.5-VL** — Alibaba, used via [MLX](https://github.com/ml-explore/mlx) and [mlx-swift-lm](https://github.com/ml-explore/mlx-swift-lm) (with [fork patches](https://github.com/NivDvir/mlx-swift-lm/tree/fix/qwen25vl-mrope) applied).
- **Apple Vision / MLX / Metal** — Apple.
- **Python reference** — [`mlx-vlm`](https://github.com/Blaizzy/mlx-vlm) by Blaizzy Pe.

[writeup]: https://dev.to/nivdvir/building-a-real-time-screen-reader-on-macos-that-actually-works-471
[upstream-pr]: https://github.com/ml-explore/mlx-swift-lm/pull/222
