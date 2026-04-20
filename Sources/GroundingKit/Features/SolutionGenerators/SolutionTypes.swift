import Foundation

/// Solution data types + registry for pre-canned solutions keyed by question keywords.
///
/// The default GroundingKit distribution ships with `all = []`. Downstream users or fork
/// maintainers can add their own `MockSolution` entries if they have pre-known answers
/// they want to serve without calling the LLM. Otherwise `findSolution(forQuestionText:)`
/// always returns nil and the LLM path (Gemini / Claude CLI) generates solutions at runtime.

/// What the human player should do with this line
public enum LineAction: String {
    case keep   // template code already in editor — just verify it's there
    case delete // editor has this line (e.g., comment) — human should remove it
    case type   // human must type this line into the editor
}

public struct SolutionLine {
    public let text: String
    public let type: String      // "key", "ctx", "boiler"
    public let section: String   // "input", "logic", "output"
    public let round: Int        // 1-4: which incremental round this line belongs to
    public let action: LineAction // what the human player does with this line

    public init(text: String, type: String, section: String, round: Int = 1, action: LineAction = .keep) {
        self.text = text; self.type = type; self.section = section; self.round = round; self.action = action
    }
}

public struct MockSolution {
    public let problemId: String
    public let keywords: [String]   // matched against question text to find the right solution
    public let lines: [SolutionLine]

    public init(problemId: String, keywords: [String], lines: [SolutionLine]) {
        self.problemId = problemId
        self.keywords = keywords
        self.lines = lines
    }
}

struct MockSolutions {

    /// Find matching solution for detected question text.
    /// Returns nil if no entry matches (the default in GroundingKit distribution).
    static func findSolution(forQuestionText text: String) -> MockSolution? {
        let lower = text.lowercased()
        var bestMatch: (sol: MockSolution, score: Int)?
        for sol in all {
            let matched = sol.keywords.filter { lower.contains($0.lowercased()) }.count
            let total = sol.keywords.count
            if matched >= max(1, Int(ceil(Double(total) * 0.75))) {
                if bestMatch == nil || matched > bestMatch!.score {
                    bestMatch = (sol, matched)
                }
            }
        }
        return bestMatch?.sol
    }

    /// Pre-canned solutions. Empty by default in the GroundingKit distribution —
    /// populate with your own entries if you want offline-ready answers for specific problems.
    static let all: [MockSolution] = []
}
