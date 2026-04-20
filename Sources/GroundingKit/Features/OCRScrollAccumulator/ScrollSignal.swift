import Foundation
import CoreGraphics

/// Detects when a panel needs scrolling and tracks scroll completion.

public class ScrollSignal {

    /// Lines that indicate end of question document (no more scroll needed)
    private static let endMarkers = ["Sample Output", "Explanation", "Note:", "Constraints"]

    /// Previous scan's visible lines (for change detection)
    private var previousVisibleLines: [String] = []

    /// Whether scroll-down signal is active
    public private(set) var needsScrollDown = false

    /// Whether we just captured new content from a scroll
    public private(set) var justCaptured = false

    /// Number of consecutive scans with identical content (stable = no more to scroll)
    private var stableCount = 0

    public init() {}

    /// Evaluate after each DeepScan: should we show scroll arrow?
    public func evaluate(visibleLines: [String], panelBounds: CGRect, lineHeight: CGFloat) {
        let cleaned = visibleLines.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }

        justCaptured = false

        // Check if content changed since last scan
        if cleaned != previousVisibleLines && !previousVisibleLines.isEmpty {
            // Content changed — either scroll happened or typing
            justCaptured = true
            stableCount = 0
        } else {
            stableCount += 1
        }

        // Check if last line looks like end of document
        let lastLine = cleaned.last ?? ""
        let atEnd = Self.endMarkers.contains(where: { lastLine.contains($0) })

        // Check if text fills the panel (suggesting more below)
        let visibleHeight = CGFloat(cleaned.count) * lineHeight
        let panelUsed = visibleHeight / max(panelBounds.height, 1)

        // Need scroll if: panel is well-filled AND not at document end AND content is stable
        if panelUsed > 0.6 && !atEnd && stableCount >= 2 {
            needsScrollDown = true
        } else {
            needsScrollDown = false
        }

        previousVisibleLines = cleaned
    }

    /// Reset (e.g., when VLM re-detects panels)
    public func reset() {
        previousVisibleLines = []
        needsScrollDown = false
        justCaptured = false
        stableCount = 0
    }
}
