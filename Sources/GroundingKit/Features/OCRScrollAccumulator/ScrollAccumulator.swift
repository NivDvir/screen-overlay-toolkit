import Foundation

/// Accumulates full document text from multiple scroll positions.
/// Uses sliding-window overlap detection with fuzzy matching.
/// Repeated lines (like "* int") are preserved because we match by position, not globally.

public class ScrollAccumulator {

    public struct AccumulatedLine {
        public let text: String
        public let quality: Int
    }

    public private(set) var lines: [AccumulatedLine] = []

    public static let qualityFull = 1
    public static let qualityBounded = 2

    public init() {}

    /// Feed new visible lines. Uses overlap detection to find where the new
    /// visible window connects to the accumulated text, then appends new lines.
    @discardableResult
    func feed(visibleLines: [String], quality: Int = 2) -> Bool {
        let cleaned = visibleLines
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }

        guard !cleaned.isEmpty else { return false }

        // First feed: add everything
        if lines.isEmpty {
            for line in cleaned {
                lines.append(AccumulatedLine(text: line, quality: quality))
            }
            return true
        }

        // Find overlap: try different overlap lengths (suffix of accumulated = prefix of visible).
        // Accept the overlap if enough lines match (≥60% of the overlap window).
        let bestOverlap = findBestOverlap(accumulated: lines.map { $0.text }, visible: cleaned)

        if bestOverlap > 0 {
            // Append only lines after the overlap
            let newStart = bestOverlap
            guard newStart < cleaned.count else { return false }
            var changed = false
            for i in newStart..<cleaned.count {
                lines.append(AccumulatedLine(text: cleaned[i], quality: quality))
                changed = true
            }
            return changed
        }

        // No overlap found — be conservative.
        // Check if visible lines are already in the accumulator:
        //   - Exact match (normalized)
        //   - Prefix match (horizontal-scroll truncation: same line, right side clipped)
        //   - Contains match ONLY when lengths are very similar (≥90% ratio)
        // NOTE: "contains" is too broad for dissimilar lines. e.g. accumulated "datatype"
        // should NOT suppress visible "* datatype" — these are different lines (template
        // vs prose). Only prefix checks are safe regardless of length ratio.
        let accNormalized = lines.map { normalize($0.text) }
        let newLines = cleaned.filter { visLine in
            let visNorm = normalize(visLine)
            // Skip if exact match exists
            if accNormalized.contains(visNorm) { return false }
            // Skip if this is a truncated version of an existing line (>=8 chars overlap)
            if visNorm.count >= 8 {
                for accLine in accNormalized {
                    guard accLine.count >= 8 else { continue }
                    // Prefix match: always safe — catches horizontal-scroll truncation
                    // where the visible line is the start of an accumulated line (or vice versa)
                    if accLine.hasPrefix(visNorm) || visNorm.hasPrefix(accLine) { return false }
                    // Contains match: only when lengths are very similar (≥90% ratio)
                    // This avoids false positives like "datatype" suppressing "* datatype"
                    let lenRatio = Double(min(visNorm.count, accLine.count)) / Double(max(visNorm.count, accLine.count))
                    if lenRatio >= 0.90 {
                        if accLine.contains(visNorm) || visNorm.contains(accLine) { return false }
                    }
                }
            }
            return true
        }

        // If most visible lines are already known, skip
        if newLines.count <= cleaned.count / 3 {
            return false
        }

        // Remaining truly new lines — but also reject editor/UI noise
        let uiNoise = ["import", "class solution", "public static", "run code",
                        "submit code", "upload", "line:", "col:", "language java",
                        "change theme", "exit full", "hackernotes"]
        let filteredNew = newLines.filter { line in
            let lower = line.lowercased()
            return !uiNoise.contains(where: { lower.hasPrefix($0) || lower.contains($0) })
        }

        for line in filteredNew {
            lines.append(AccumulatedLine(text: line, quality: quality))
        }
        return !filteredNew.isEmpty
    }

    /// Find the best overlap length where accumulated suffix matches visible prefix.
    /// Returns the overlap length (number of visible lines that overlap), or 0 if none.
    private func findBestOverlap(accumulated: [String], visible: [String]) -> Int {
        let maxOverlap = min(accumulated.count, visible.count)
        var bestOverlap = 0
        var bestScore: Double = 0

        for overlapLen in 1...maxOverlap {
            let accSuffix = Array(accumulated.suffix(overlapLen))
            let visPre = Array(visible.prefix(overlapLen))

            // Count matching lines
            var matches = 0
            for (accLine, visLine) in zip(accSuffix, visPre) {
                if linesMatch(accLine, visLine) {
                    matches += 1
                }
            }

            let matchRatio = Double(matches) / Double(overlapLen)

            // Accept if ≥60% match AND at least 2 lines match (or all match if overlap ≤ 2)
            let minMatches = overlapLen <= 2 ? overlapLen : 2
            if matchRatio >= 0.6 && matches >= minMatches {
                // Prefer longer overlaps with good match ratio
                let score = Double(matches) * matchRatio
                if score > bestScore {
                    bestScore = score
                    bestOverlap = overlapLen
                }
            }
        }

        return bestOverlap
    }

    /// Count how many lines at the tail of accumulated also appear at the tail of visible.
    /// Used to detect "same content, no scroll" situations.
    private func countTailMatches(accumulated: [String], visible: [String]) -> Int {
        let maxCheck = min(accumulated.count, visible.count, 5)
        var matches = 0
        for i in 0..<maxCheck {
            let accIdx = accumulated.count - 1 - i
            let visIdx = visible.count - 1 - i
            if linesMatch(accumulated[accIdx], visible[visIdx]) {
                matches += 1
            }
        }
        return matches
    }

    /// Check if two lines match (exact normalized or fuzzy for longer lines)
    private func linesMatch(_ a: String, _ b: String) -> Bool {
        let na = normalize(a)
        let nb = normalize(b)
        if na == nb { return true }
        if na.count > 10 || nb.count > 10 {
            return FuzzyMatch.similarity(a, b) > 0.80
        }
        return false
    }

    /// Extend an existing accumulated line with newly visible right-side text.
    /// Used after horizontal scroll reveals content clipped at panel edge.
    /// Matches by text overlap (suffix of existing = prefix of new), not Y position.
    /// Returns true if any line was extended.
    @discardableResult
    func extendLine(withText newText: String) -> Bool {
        let cleanNew = newText.trimmingCharacters(in: .whitespaces)
        guard cleanNew.count >= 5 else { return false }

        // Find the accumulated line whose suffix best overlaps with new text's prefix
        var bestIdx: Int?
        var bestOverlap = 0

        for (i, line) in lines.enumerated() {
            let overlap = findCharOverlap(suffix: line.text, prefix: cleanNew)
            if overlap > bestOverlap {
                bestOverlap = overlap
                bestIdx = i
            }
        }

        guard let idx = bestIdx, bestOverlap >= 3 else { return false }

        let existing = lines[idx].text
        let remainder = String(cleanNew.dropFirst(bestOverlap))
        if !remainder.trimmingCharacters(in: .whitespaces).isEmpty {
            let extended = existing + remainder
            lines[idx] = AccumulatedLine(text: extended, quality: lines[idx].quality)
            NSLog("ScrollAccumulator: extended line %d (+%d chars): '%@'",
                  idx, remainder.count, String(extended.suffix(40)))
            return true
        }
        return false
    }

    /// Find the longest overlap where `suffix`'s tail matches `prefix`'s head
    private func findCharOverlap(suffix: String, prefix: String) -> Int {
        let sChars = Array(suffix)
        let pChars = Array(prefix)
        let maxLen = min(sChars.count, pChars.count)

        var best = 0
        for len in 1...maxLen {
            let sTail = sChars.suffix(len)
            let pHead = pChars.prefix(len)
            if Array(sTail) == Array(pHead) {
                best = len
            }
        }
        return best
    }

    var accumulatedLines: [String] { lines.map { $0.text } }
    var fullText: String { accumulatedLines.joined(separator: "\n") }

    private func normalize(_ text: String) -> String {
        text.lowercased()
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespaces)
    }

    func reset() {
        lines = []
    }
}
