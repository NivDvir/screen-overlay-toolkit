# Feature: OCRScrollAccumulator

Read text out of any scrollable on-screen region — even when the content exceeds the viewport. Combines Apple Vision OCR, scroll-need detection, and Levenshtein-based fuzzy stitching to build a complete transcript from multiple scroll snapshots.

## Why this exists

OCR a screenshot once → you get only the visible part. Scroll down → OCR again → now you have overlap + new lines. Naive concatenation produces duplicated text with OCR-jitter mismatches at the seam. This feature solves that with fuzzy overlap detection (Levenshtein similarity ≥ 60%).

## Standalone use

```swift
// 1. Configure (optional — defaults are reasonable)
OCRScanner.sidebarLabels = ["editorial", "discussions"]  // filter noise
OCRScanner.editorThemeIsDark = true

// 2. First scan — what's visible now
let firstScan = await OCRScanner.scanWithBounds(
    image: screenImage,
    questionBounds: CGRect(x: 100, y: 200, width: 600, height: 400),
    editorBounds: .zero  // no editor, just one panel
)
let accumulator = ScrollAccumulator()
accumulator.ingest(firstScan.question.lines)

// 3. Check if there's more below the fold
let scrollSignal = ScrollSignal()
scrollSignal.evaluate(scan: firstScan)
if scrollSignal.needsScrollDown {
    // Emit a scroll event (use CGEvent or your own input-sim code),
    // wait ~300ms, then capture + scan + ingest again:
    let nextScan = await OCRScanner.scanWithBounds(image: capture(), ...)
    accumulator.ingest(nextScan.question.lines)
}

// 4. Read the full transcript
let fullText = accumulator.fullText  // stitched, deduped
```

## What's in this folder

| File | Purpose |
|------|---------|
| `OCRScanner.swift` | Apple Vision OCR wrapper — scan full screen or bounded panels. Returns `ScanResult` with per-panel `[DetectedLine]`. |
| `ScrollAccumulator.swift` | Dedup + stitch: fuzzy-matches new lines against previously-ingested lines to avoid duplicates across scroll frames. |
| `ScrollSignal.swift` | Compares successive scans — if the visible lines haven't changed but expected to (based on content size), fires `needsScrollDown`. |
| `HScrollSignal.swift` | Same concept for horizontal truncation (when lines are cut at the right edge of a panel). |
| `FuzzyMatch.swift` | Levenshtein edit distance + OCR-aware normalization (lowercase, whitespace collapse, bullet `•→*`). |

## Dependencies

- **External:** `Vision` framework (Apple, built-in on macOS).
- **Internal (within GroundingKit):** none. Fully self-contained.

## Public API surface

- `OCRScanner` — static entry points: `scanFull`, `scanWithBounds`
- `ScanResult`, `PanelState`, `DetectedLine` — data types
- `ScrollAccumulator` — `.ingest(lines)`, `.fullText`, `.reset()`
- `ScrollSignal`, `HScrollSignal` — `.evaluate(scan:)`, `.needsScrollDown`/`.needsScrollRight`
- `FuzzyMatch.similarity(_:_:)` — utility for comparing strings OCR-tolerantly

## Tuning notes

- **Levenshtein threshold**: `FuzzyMatch.normalize` + 60% similarity is the sweet spot for CODE content (where `|` vs `l` vs `I` ambiguity is common).
  - 40% = too permissive, novel lines classified as duplicates and dropped.
  - 80% = too strict, OCR jitter creates false "novel" lines.
- **Vision recognition level**: use `.accurate` (level 0), not `.fast` (level 1). The API naming is counterintuitive.
- **Use `VNRecognizeTextRequest`**, NOT `RecognizeDocumentsRequest` — the newer API silently drops code-formatted lines (indented with brackets/semicolons).
