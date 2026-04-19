import Foundation

/// Shared fuzzy match for comparing OCR'd code text against solution lines.
/// Uses Levenshtein edit distance with code-specific normalization.

enum FuzzyMatch {

    /// Normalize code text for comparison: handle common OCR errors
    static func normalize(_ text: String) -> String {
        var s = text.trimmingCharacters(in: .whitespaces).lowercased()
        // Strip leading line numbers (e.g., "12  for(..." → "for(...")
        if let range = s.range(of: #"^\d+\s+"#, options: .regularExpression) {
            s.removeSubrange(range)
        }
        // Normalize common OCR confusions
        s = s.replacingOccurrences(of: "|", with: "l")  // pipe → l
        // Normalize whitespace
        s = s.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
        return s
    }

    /// Levenshtein edit distance between two strings
    static func levenshtein(_ a: String, _ b: String) -> Int {
        let a = Array(a), b = Array(b)
        let m = a.count, n = b.count
        if m == 0 { return n }
        if n == 0 { return m }

        var prev = Array(0...n)
        var curr = [Int](repeating: 0, count: n + 1)

        for i in 1...m {
            curr[0] = i
            for j in 1...n {
                let cost = a[i-1] == b[j-1] ? 0 : 1
                curr[j] = min(prev[j] + 1, curr[j-1] + 1, prev[j-1] + cost)
            }
            swap(&prev, &curr)
        }
        return prev[n]
    }

    /// Similarity score between 0.0 and 1.0 (1.0 = identical)
    static func similarity(_ a: String, _ b: String) -> Double {
        let na = normalize(a)
        let nb = normalize(b)
        guard !na.isEmpty && !nb.isEmpty else { return 0 }

        // Quick exact match
        if na == nb { return 1.0 }

        // Containment check (one contains the other)
        if na.contains(nb) || nb.contains(na) {
            return Double(min(na.count, nb.count)) / Double(max(na.count, nb.count))
        }

        // Levenshtein-based similarity
        let dist = levenshtein(na, nb)
        let maxLen = max(na.count, nb.count)
        return 1.0 - Double(dist) / Double(maxLen)
    }

    /// Does detected text match solution text? (threshold 0.65 for code)
    static func matches(_ detected: String, _ solution: String, threshold: Double = 0.65) -> Bool {
        return similarity(detected, solution) >= threshold
    }
}
