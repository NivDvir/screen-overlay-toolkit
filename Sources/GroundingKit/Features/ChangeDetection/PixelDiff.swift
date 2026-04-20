import CoreGraphics
import AppKit

/// Fast pixel-diff keystroke detector (Tier-1).
/// Captures only the editor region, hashes line-height bands, compares with previous frame.
/// Detects which line changed in <15ms without OCR.

public class PixelDiff {

    private var previousBandHashes: [UInt64] = []
    /// Stores the hash from 2 frames ago — used to detect cursor blink (toggle pattern)
    private var twoFramesAgoBandHashes: [UInt64] = []
    private var editorBounds: CGRect = .zero
    private var lineHeight: CGFloat = 21
    private var overlayWindowID: CGWindowID = 0

    /// Last detected change: which band (line index) changed, and its Y position
    public private(set) var changedLineY: CGFloat?
    public private(set) var lastChangeTime: CFAbsoluteTime = 0

    public init() {}

    public func configure(editorBounds: CGRect, lineHeight: CGFloat, overlayWindowID: CGWindowID) {
        self.editorBounds = editorBounds
        self.lineHeight = max(lineHeight, 10)
        self.overlayWindowID = overlayWindowID
    }

    /// Run one diff cycle. Returns true if a change was detected.
    @discardableResult
    public func detectChange() -> Bool {
        guard editorBounds.width > 50, editorBounds.height > 20 else { return false }

        let scale = screenScaleFactor

        // Capture ONLY the editor region (cropped = faster)
        let pixelRect = CGRect(
            x: editorBounds.minX * scale,
            y: editorBounds.minY * scale,
            width: editorBounds.width * scale,
            height: editorBounds.height * scale
        )

        // autoreleasepool: CGWindowListCreateImage + dataProvider retain large buffers.
        // At 20 calls/sec without this, memory grows ~50MB/sec.
        var currentHashes: [UInt64] = []
        let ok: Bool = autoreleasepool {
            guard let image = CGWindowListCreateImage(
                pixelRect,
                .optionOnScreenBelowWindow,
                overlayWindowID,
                [.bestResolution, .boundsIgnoreFraming]
            ) else { return false }

            let imgW = image.width
            let imgH = image.height
            guard imgW > 10, imgH > 10 else { return false }

            guard let dataProvider = image.dataProvider,
                  let data = dataProvider.data else { return false }
            let ptr = CFDataGetBytePtr(data)!
            let bytesPerRow = image.bytesPerRow

            let bandHeight = Int(lineHeight * scale)
            guard bandHeight > 0 else { return false }
            let numBands = imgH / bandHeight

            currentHashes.reserveCapacity(numBands)

            for band in 0..<numBands {
                let startRow = band * bandHeight
                var hash: UInt64 = 0
                let rowStep = max(1, bandHeight / 4)
                let colStep = 8 * 4
                for row in stride(from: startRow, to: min(startRow + bandHeight, imgH), by: rowStep) {
                    let rowStart = row * bytesPerRow
                    for col in stride(from: 0, to: min(imgW * 4, bytesPerRow), by: colStep) {
                        let idx = rowStart + col
                        hash = hash &* 1099511628211
                        hash ^= UInt64(ptr[idx])
                        hash ^= UInt64(ptr[idx + 1]) << 8
                        hash ^= UInt64(ptr[idx + 2]) << 16
                    }
                }
                currentHashes.append(hash)
            }
            return true
        }

        guard ok else { return false }

        // Compare with previous frame — filter out cursor blink.
        // Cursor blink pattern: hash toggles between two values (on/off) in a single band.
        // Real typing: hash changes to a NEW value (not seen 2 frames ago).
        var changedBands: [Int] = []

        if previousBandHashes.count == currentHashes.count {
            for i in 0..<currentHashes.count {
                if currentHashes[i] != previousBandHashes[i] {
                    // Check if this is just cursor blink: current == twoFramesAgo means toggle
                    let isBlink = twoFramesAgoBandHashes.count == currentHashes.count
                        && currentHashes[i] == twoFramesAgoBandHashes[i]
                    if !isBlink {
                        changedBands.append(i)
                    }
                }
            }
        } else if !previousBandHashes.isEmpty {
            changedBands = Array(0..<currentHashes.count)  // Window resize — treat all as changed
        }

        twoFramesAgoBandHashes = previousBandHashes
        previousBandHashes = currentHashes

        let changed = !changedBands.isEmpty
        if changed, let lastBand = changedBands.last {
            changedLineY = editorBounds.minY + CGFloat(lastBand) * lineHeight + lineHeight / 2
            lastChangeTime = CFAbsoluteTimeGetCurrent()
            NSLog("PixelDiff: real change in %d band(s), last at band %d (Y=%.0f)",
                  changedBands.count, lastBand, changedLineY ?? 0)
        }

        return changed
    }

    /// Reset (e.g., after VLM re-detection changes bounds)
    public func reset() {
        previousBandHashes = []
        twoFramesAgoBandHashes = []
        changedLineY = nil
    }
}
