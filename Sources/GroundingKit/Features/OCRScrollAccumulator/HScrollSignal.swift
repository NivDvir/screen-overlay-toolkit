import Foundation
import CoreGraphics

/// Detects when lines are truncated at the right edge of a panel,
/// indicating a horizontally scrollable sub-panel (e.g. code blocks that exceed panel width).

public class HScrollSignal {

    public init() {}


    /// Whether horizontal scroll-right signal is active
    private(set) var needsScrollRight = false

    /// Whether content just changed after a horizontal scroll
    private(set) var justCaptured = false

    /// Inferred bounds of the inner scrollable sub-panel
    private(set) var subPanelBounds: CGRect?

    /// Y positions of truncated lines (for marker placement)
    private(set) var truncatedLineYs: [CGFloat] = []

    /// Previous scan's truncated line texts (for change detection)
    private var previousTruncatedTexts: [String] = []

    /// Consecutive scans with identical truncated content
    private var stableCount = 0

    /// How close to the panel's right edge a line must end to be "truncated" (logical px)
    private let edgeThreshold: CGFloat = 15

    /// Minimum truncated lines to declare a sub-panel cluster
    private let minClusterSize = 2

    /// Evaluate after each DeepScan: are there right-truncated lines?
    func evaluate(visibleLines: [DetectedLine], panelBounds: CGRect) {
        justCaptured = false

        guard panelBounds.width > 50 else {
            needsScrollRight = false
            return
        }

        // Find lines whose right edge abuts the panel's right edge
        let panelRight = panelBounds.maxX
        let truncated = visibleLines.filter { line in
            line.bounds.maxX >= panelRight - edgeThreshold &&
            line.bounds.width > 30 &&       // skip tiny fragments
            line.text.count > 5             // skip short labels
        }

        let truncTexts = truncated.map { $0.text }

        // Change detection
        if truncTexts != previousTruncatedTexts && !previousTruncatedTexts.isEmpty {
            justCaptured = true
            stableCount = 0
        } else {
            stableCount += 1
        }
        previousTruncatedTexts = truncTexts

        // Need at least minClusterSize truncated lines at a consistent right edge
        guard truncated.count >= minClusterSize else {
            needsScrollRight = false
            subPanelBounds = nil
            truncatedLineYs = []
            return
        }

        // Group by maxX — lines in the same sub-panel share the same right boundary
        let maxXValues = truncated.map { $0.bounds.maxX }
        let medianMaxX = maxXValues.sorted()[maxXValues.count / 2]

        // Filter to lines within 8px of median right edge
        let cluster = truncated.filter { abs($0.bounds.maxX - medianMaxX) < 8 }

        guard cluster.count >= minClusterSize else {
            needsScrollRight = false
            subPanelBounds = nil
            truncatedLineYs = []
            return
        }

        // Compute sub-panel bounds from cluster
        let minX = cluster.map { $0.bounds.minX }.min()!
        let minY = cluster.map { $0.bounds.minY }.min()! - 5
        let maxX = cluster.map { $0.bounds.maxX }.max()!
        let maxY = cluster.map { $0.bounds.maxY }.max()! + 5

        subPanelBounds = CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
        truncatedLineYs = cluster.map { $0.bounds.midY }

        // Assert signal after stable detection (2+ consistent scans)
        needsScrollRight = stableCount >= 2
    }

    func reset() {
        needsScrollRight = false
        justCaptured = false
        subPanelBounds = nil
        truncatedLineYs = []
        previousTruncatedTexts = []
        stableCount = 0
    }
}
