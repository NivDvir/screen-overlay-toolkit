import Foundation
import CoreGraphics

/// Generates positioned ghost clues from content state.
/// Each clue is a piece of ghost text rendered at exact editor coordinates.

public struct GhostClue {
    public let text: String
    public let x: CGFloat          // X position for the text box
    public let y: CGFloat          // Y position for the text box
    public let dashY: CGFloat      // Y for the dashed insertion line (between existing rows)
    public let dashEndX: CGFloat   // X where dashed line ends / box connects
    public let type: GhostType
    public let solutionIndex: Int

    public init(text: String, x: CGFloat, y: CGFloat, dashY: CGFloat, dashEndX: CGFloat, type: GhostType, solutionIndex: Int) {
        self.text = text
        self.x = x
        self.y = y
        self.dashY = dashY
        self.dashEndX = dashEndX
        self.type = type
        self.solutionIndex = solutionIndex
    }
}

public enum GhostType: String {
    case deleteMarker = "delete"      // line to remove — solid strikethrough + X
    case insertMarker = "insert"      // next line to type — dashed line + box
    case typedConfirm = "typed_ok"    // ✓ line just typed — brief confirmation flash
    case codeKey = "code_key"         // (legacy)
    case codeCtx = "code_ctx"         // (legacy)
    case codeBoiler = "code_boiler"   // (legacy)
    case nextAction = "next_action"   // (legacy)
    case progress = "progress"        // progress indicator
    case scrollDown = "scroll_down"   // ▼ scroll signal on question panel
    case scrollCaptured = "captured"  // ✓ scroll content captured confirmation
    case scrollRight = "scroll_right"      // ▶ horizontal scroll signal on sub-panel
    case scrollRightCaptured = "hcaptured" // ✓ horizontal capture confirmation
    case actionLabel = "action_label" // step label: "STEP 3/12 — type next line:"
    case mcqAnswer = "mcq_answer"      // ➜ green arrow pointing at correct MCQ answer
    case mcqLabel = "mcq_label"        // "Answer: B" label on question panel
}

public struct GhostLayout {

    /// Platform-specific UI keywords to ignore in editor OCR. Populate via PlatformConfig
    /// at startup. Default is empty (no UI filtering). Typical entries for coding platforms
    /// include editor chrome like "Run", "Submit", "Line:", "Col:", etc.
    public static var uiKeywords: [String] = []

    /// Generate ghost clues positioned in the editor panel.
    ///
    /// Strategy: Walk through the solution in order. For each line:
    /// Generate ghost clues in priority order:
    /// 1. DELETE markers — for editor lines NOT in solution (e.g., comments to remove)
    /// 2. ONE INSERT marker — for the NEXT missing solution line to type
    /// 3. Progress indicator
    public static func generateClues(from state: ContentState) -> [GhostClue] {
        guard let solution = state.solution else { return [] }

        let editorBounds = state.editorBounds
        let editorRight = editorBounds.maxX
        let editorLeft = editorBounds.minX + 50  // past line numbers
        let lineHeight = state.lineHeight

        var clues: [GhostClue] = []

        // --- STEP 1: DELETE markers ---
        // Find editor lines that are NOT in the solution (should be removed)
        // Only mark CODE lines, not UI elements (buttons, status text)
        let solutionTexts = solution.lines.map { $0.text.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        let uiKeywords = Self.uiKeywords

        for editorLine in state.editorLines {
            let edText = editorLine.text.trimmingCharacters(in: .whitespaces)
            guard !edText.isEmpty else { continue }
            // Skip UI elements
            guard !uiKeywords.contains(where: { edText.contains($0) }) else { continue }
            // Skip lines OUTSIDE editor bounds (prevents question-area text from getting delete markers)
            guard editorLine.bounds.midX >= editorBounds.minX &&
                  editorLine.bounds.midX <= editorBounds.maxX else { continue }
            guard editorLine.bounds.midY >= editorBounds.minY &&
                  editorLine.bounds.midY < editorBounds.maxY - 50 else { continue }

            let inSolution = solutionTexts.contains { fuzzyMatch(edText, $0) }
            if !inSolution {
                clues.append(GhostClue(
                    text: edText,
                    x: editorLine.bounds.minX,
                    y: editorLine.bounds.midY,
                    dashY: editorLine.bounds.midY,
                    dashEndX: editorLine.bounds.maxX,
                    type: .deleteMarker,
                    solutionIndex: -1
                ))
            }
        }

        // --- STEP 1b: DELETE markers for solution lines with action=.delete ---
        // These are comments like "//Write your code here" that the human should remove.
        for delMarker in state.deleteMarkers {
            clues.append(GhostClue(
                text: delMarker.text,
                x: editorLeft,
                y: delMarker.insertAfterY,
                dashY: delMarker.insertAfterY,
                dashEndX: editorRight - 50,
                type: .deleteMarker,
                solutionIndex: delMarker.solutionIndex
            ))
        }

        // --- STEP 2a: Typed confirmation (if a line was just confirmed) ---
        if let justTyped = state.lastTypedConfirmation {
            clues.append(GhostClue(
                text: "✓ typed",
                x: editorRight - 60,
                y: justTyped.y,
                dashY: 0, dashEndX: 0,
                type: .typedConfirm,
                solutionIndex: -1
            ))
        }

        // --- STEP 2b: Action label — "STEP N/M — type next line:" ---
        let totalLines = solution.lines.filter { !$0.text.trimmingCharacters(in: .whitespaces).isEmpty }.count
        let typedSoFar = state.typedCount
        if !state.missingLines.isEmpty {
            let stepNum = typedSoFar + 1
            let roundInfo = state.totalRounds > 1 ? " (R\(state.currentRound))" : ""
            clues.append(GhostClue(
                text: "STEP \(stepNum)/\(totalLines)\(roundInfo) — type next line:",
                x: editorLeft + 100,
                y: editorBounds.minY - 22,
                dashY: 0, dashEndX: 0,
                type: .actionLabel,
                solutionIndex: -1
            ))
        }

        // --- STEP 2c: ONE INSERT marker (the next missing line) ---
        if let firstMissing = state.missingLines.first {
            let anchorY = firstMissing.insertAfterY

            // Sort editor lines by Y to find the gap
            let sortedLines = state.editorLines
                .filter { !$0.text.trimmingCharacters(in: .whitespaces).isEmpty }
                .sorted { $0.bounds.midY < $1.bounds.midY }

            // Find the two adjacent lines that bracket the insertion point
            var gapTop: CGFloat = anchorY
            var gapBottom: CGFloat = anchorY + lineHeight

            for i in 0..<sortedLines.count {
                if sortedLines[i].bounds.midY >= anchorY - 2 {
                    // This line is at or just below the anchor
                    gapTop = sortedLines[i].bounds.maxY
                    if i + 1 < sortedLines.count {
                        gapBottom = sortedLines[i + 1].bounds.minY
                    } else {
                        gapBottom = gapTop + lineHeight
                    }
                    break
                }
            }

            // dashY = midpoint of the gap BETWEEN the two code rows
            let dashY = (gapTop + gapBottom) / 2

            // Box: to the RIGHT, past where the nearby code text ends
            let nearbyMaxX = sortedLines
                .filter { abs($0.bounds.midY - dashY) < lineHeight * 2 }
                .map { $0.bounds.maxX }.max() ?? editorLeft
            let boxX = max(nearbyMaxX + 30, editorRight - 280)

            clues.append(GhostClue(
                text: firstMissing.text,
                x: boxX,
                y: dashY,               // box at same Y as the gap
                dashY: dashY,            // dashed line IN THE GAP between rows
                dashEndX: editorLeft,    // dashed line starts from left
                type: .insertMarker,
                solutionIndex: firstMissing.solutionIndex
            ))
        }

        // --- STEP 3: Scroll signal (if question panel needs scrolling) ---
        let qBounds = state.questionBounds
        if qBounds != .zero {
            if state.questionScrollSignal.needsScrollDown {
                clues.append(GhostClue(
                    text: "▼ scroll down ▼",
                    x: qBounds.midX,
                    y: qBounds.maxY - 20,
                    dashY: 0, dashEndX: 0,
                    type: .scrollDown,
                    solutionIndex: -1
                ))
            } else if state.questionScrollSignal.justCaptured {
                clues.append(GhostClue(
                    text: "✓ captured",
                    x: qBounds.midX,
                    y: qBounds.maxY - 20,
                    dashY: 0, dashEndX: 0,
                    type: .scrollCaptured,
                    solutionIndex: -1
                ))
            }
        }

        // --- STEP 3b: Horizontal scroll signal (if sub-panel needs scrolling right) ---
        if let spBounds = state.hScrollSignal.subPanelBounds {
            if state.hScrollSignal.needsScrollRight {
                clues.append(GhostClue(
                    text: "\u{25B6} scroll right \u{25B6}",
                    x: spBounds.maxX + 10,
                    y: spBounds.midY,
                    dashY: 0, dashEndX: 0,
                    type: .scrollRight,
                    solutionIndex: -1
                ))
            } else if state.hScrollSignal.justCaptured {
                clues.append(GhostClue(
                    text: "\u{2713} captured",
                    x: spBounds.maxX + 10,
                    y: spBounds.midY,
                    dashY: 0, dashEndX: 0,
                    type: .scrollRightCaptured,
                    solutionIndex: -1
                ))
            }
        }

        // --- STEP 4: Progress ---
        let total = solution.lines.count
        let pct = state.typedCount * 100 / max(total, 1)
        clues.append(GhostClue(
            text: "\(state.typedCount)/\(total) (\(pct)%) R\(state.currentRound)/\(state.totalRounds)",
            x: editorRight - 140,
            y: editorBounds.minY - 5,
            dashY: 0, dashEndX: 0,
            type: .progress,
            solutionIndex: -1
        ))

        return clues
    }

    /// Generate MCQ clues — green arrows pointing at correct answer options.
    public static func generateMCQClues(from state: ContentState) -> [GhostClue] {
        guard let mcq = state.mcqAnswer else { return [] }

        let editorBounds = state.editorBounds
        let questionBounds = state.questionBounds
        var clues: [GhostClue] = []

        // Find answer option lines in the editor panel
        // Filter out UI chrome, keep only answer text lines
        let answerLines = state.editorLines.filter { line in
            let t = line.text.trimmingCharacters(in: .whitespaces)
            guard !t.isEmpty else { return false }
            // Skip known UI elements
            let uiKeywords = Self.uiKeywords
            if uiKeywords.contains(where: { t.contains($0) }) { return false }
            // Skip lines outside editor Y bounds
            guard line.bounds.midY >= editorBounds.minY + 20 &&
                  line.bounds.midY <= editorBounds.maxY - 20 else { return false }
            // Skip very short lines (likely UI labels like "Answers")
            guard t.count >= 2 else { return false }
            return true
        }

        // Place green arrows at correct answer positions
        for idx in mcq.correctIndices {
            guard idx < answerLines.count else { continue }
            let answerLine = answerLines[idx]

            clues.append(GhostClue(
                text: "➜",
                x: answerLine.bounds.minX - 30,
                y: answerLine.bounds.midY,
                dashY: 0, dashEndX: 0,
                type: .mcqAnswer,
                solutionIndex: idx
            ))
        }

        // Show "Answer: B" or "Answers: A, C" label on question panel
        if questionBounds != .zero {
            clues.append(GhostClue(
                text: "Answer: \(mcq.letters)",
                x: questionBounds.midX,
                y: questionBounds.maxY - 40,
                dashY: 0, dashEndX: 0,
                type: .mcqLabel,
                solutionIndex: -1
            ))
        }

        return clues
    }

    /// Ensure no two ghost clues overlap — if they're within lineHeight/2, push them apart
    private static func spreadOverlapping(_ clues: [GhostClue], lineHeight: CGFloat, editorMaxY: CGFloat) -> [GhostClue] {
        guard clues.count > 1 else { return clues }

        var result = clues.sorted { $0.y < $1.y }
        let minSpacing = lineHeight * 0.8

        for i in 1..<result.count {
            let gap = result[i].y - result[i-1].y
            if gap < minSpacing {
                let newY = min(result[i-1].y + minSpacing, editorMaxY - 5)
                result[i] = GhostClue(
                    text: result[i].text,
                    x: result[i].x,
                    y: newY,
                    dashY: result[i].dashY,
                    dashEndX: result[i].dashEndX,
                    type: result[i].type,
                    solutionIndex: result[i].solutionIndex
                )
            }
        }

        return result
    }

    private static func fuzzyMatch(_ detected: String, _ solution: String) -> Bool {
        FuzzyMatch.matches(detected, solution)
    }
}
