# Feature: ChangeDetection

Fast pixel-level change detection for a screen region via banded DCT hashing. Detects "did anything change since last call?" in ~50ms without full re-OCR.

## Why this exists

Running full OCR every tick is expensive (~300ms per frame). `PixelDiff` tells you whether the target region is stable or mid-keystroke, so you can:
- Skip OCR when nothing's changed
- Trigger OCR immediately after user finishes typing (a single "settled" hash)
- Filter out cursor-blink jitter

## Standalone use

```swift
let pixelDiff = PixelDiff()

// Initial reference
if let image = captureScreen() {
    pixelDiff.capture(region: editorBounds, from: image)
}

// Later, detect changes
if let newImage = captureScreen() {
    let stability = pixelDiff.compare(region: editorBounds, from: newImage)
    // stability is one of:
    //   .identical   → no change, don't re-OCR
    //   .minorShift  → cursor blink / scrollbar move — probably ignore
    //   .changed     → real edit, re-OCR now
}
```

## What's in this folder

| File | Purpose |
|------|---------|
| `PixelDiff.swift` | Hash-based change detector. Divides region into horizontal bands, DCT-hashes each, compares. |

## Dependencies

- **External:** `CoreGraphics` (built-in).
- **Internal:** none.

## Public API surface

- `PixelDiff()` — create instance
- `.capture(region:from:)` — set reference
- `.compare(region:from:)` → `.identical` | `.minorShift` | `.changed`

## Notes

- Band-based hashing is robust to minor shifts (cursor blink) but catches real content changes.
- 50ms latency on M1 Pro for a typical editor region.
- Not suitable for regions with animations (videos, typing carets) unless you tune the `.minorShift` threshold.
