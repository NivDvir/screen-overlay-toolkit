import Foundation
import CoreGraphics

/// Question type detected from editor panel content
enum QuestionType { case coding, mcq, unknown }

/// MCQ answer from LLM
struct MCQAnswer {
    let correctIndices: [Int]  // 0-based indices of correct options
    let letters: String        // "A, B, C" or "B"
    let numbers: String        // "2" or "1, 3" (1-based)
    let questionSent: String   // the exact question text sent to LLM
    let optionsSent: String    // the options text sent to LLM
    let rawResponse: String    // LLM's raw response before parsing
}

/// Tracks the complete state of both panels + solution progress across scans.
/// Thread-safe: all mutations go through the serial queue.

class ContentState {

    private let queue = DispatchQueue(label: "com.groundingkit.contentstate")

    // Question panel
    private var _questionText: String = ""
    private var _questionBounds: CGRect = .zero
    let questionAccumulator = ScrollAccumulator()
    let questionScrollSignal = ScrollSignal()
    let hScrollSignal = HScrollSignal()
    var questionText: String { queue.sync { _questionText } }
    var questionBounds: CGRect {
        get { queue.sync { _questionBounds } }
        set { queue.sync { _questionBounds = newValue } }
    }

    // Editor panel
    private var _editorLines: [DetectedLine] = []
    private var _editorBounds: CGRect = .zero
    private var _lineHeight: CGFloat = 18
    var editorLines: [DetectedLine] { queue.sync { _editorLines } }
    var editorBounds: CGRect {
        get { queue.sync { _editorBounds } }
        set { queue.sync { _editorBounds = newValue } }
    }
    var lineHeight: CGFloat { queue.sync { _lineHeight } }

    // Typed-line confirmation (brief flash when a line is detected as typed)
    struct TypedConfirmation {
        let y: CGFloat       // Y position of the confirmed line
        let timestamp: Date  // when it was confirmed — auto-clears after 2s
    }
    private var _lastTypedConfirmation: TypedConfirmation?
    private var _previousTypedCount: Int = 0
    var lastTypedConfirmation: TypedConfirmation? {
        queue.sync {
            guard let conf = _lastTypedConfirmation else { return nil }
            // Auto-expire after 2 seconds
            if Date().timeIntervalSince(conf.timestamp) > 2.0 {
                _lastTypedConfirmation = nil
                return nil
            }
            return conf
        }
    }

    // Solution
    private var _solution: MockSolution?
    private var _missingLines: [MissingLine] = []
    private var _typedCount: Int = 0
    private var _currentRound: Int = 1
    private var _totalRounds: Int = 1
    private var _geminiRequested: Bool = false   // true while a Gemini request is in flight or completed
    private var _claudeInFlight: Bool = false    // true ONLY while waiting for Claude CLI response
    private var _needsVisualReset: Bool = false  // signals main loop to reset VLM bounds + clear overlay
    private var _scansSinceTextStable: Int = 0   // count scans where question text didn't grow
    private var _lastQuestionTextLength: Int = 0 // for detecting when accumulation stalls
    var solution: MockSolution? {
        get { queue.sync { _solution } }
        set { queue.sync { _solution = newValue } }
    }
    var missingLines: [MissingLine] { queue.sync { _missingLines } }
    private var _deleteMarkers: [MissingLine] = []
    var deleteMarkers: [MissingLine] { queue.sync { _deleteMarkers } }

    // MCQ support
    private var _questionType: QuestionType = .unknown
    private var _mcqAnswer: MCQAnswer?
    private var _mcqRequested: Bool = false
    private var _lastMCQQuestionHash: String = ""  // detect question changes
    private var _mcqAnswerCache: [String: MCQAnswer] = [:]  // hash → cached answer (survives question switches)
    // Coding question switching
    private var _lastCodingQuestionHash: String = ""  // detect coding question changes
    private var _codingSolutionCache: [String: MockSolution] = [:]  // hash → cached solution (survives question switches)
    var questionType: QuestionType { queue.sync { _questionType } }
    var claudeInFlight: Bool { queue.sync { _claudeInFlight } }
    var mcqAnswer: MCQAnswer? { queue.sync { _mcqAnswer } }
    var mcqRequested: Bool { queue.sync { _mcqRequested } }

    /// Check and consume the visual reset flag.
    /// Returns true once, then resets to false.
    func consumeVisualReset() -> Bool {
        queue.sync {
            if _needsVisualReset {
                _needsVisualReset = false
                return true
            }
            return false
        }
    }

    /// Set MCQ answer (thread-safe). Also caches by question hash for instant recall.
    func setMCQAnswer(_ answer: MCQAnswer) {
        queue.sync {
            // Guard: if the question changed while Claude was working, discard the stale answer.
            // Compare the question text that was sent to Claude with the current question text.
            let currentQ = _questionText.prefix(60)
            let sentQ = answer.questionSent.prefix(60)
            if !currentQ.isEmpty && !sentQ.isEmpty && currentQ != sentQ {
                NSLog("ContentState: MCQ answer DISCARDED — question changed while Claude was working (sent: '%@…', current: '%@…')",
                      String(sentQ), String(currentQ))
                // Don't set the answer — let the new question's Claude call handle it
                return
            }

            _mcqAnswer = answer
            if !_lastMCQQuestionHash.isEmpty {
                _mcqAnswerCache[_lastMCQQuestionHash] = answer
                NSLog("ContentState: MCQ answer set: %@ (cached, %d total)", answer.letters, _mcqAnswerCache.count)
            } else {
                NSLog("ContentState: MCQ answer set: %@", answer.letters)
            }
        }
    }
    var currentRound: Int { queue.sync { _currentRound } }
    var totalRounds: Int { queue.sync { _totalRounds } }
    var typedCount: Int { queue.sync { _typedCount } }

    /// Update from a deep scan result (thread-safe)
    func update(from scan: ScanResult) {
        queue.sync {
            // Visible question lines from current scan — used for question change detection
            // outside the `if let q` block (MCQ and coding hash checks need it)
            var latestVisibleLines: [String] = []

            if let q = scan.questionPanel {
                // Check for external reset signal (test harness can request fresh start)
                let resetPath = "/tmp/ccsv_reset_flag"
                if FileManager.default.fileExists(atPath: resetPath) {
                    questionAccumulator.reset()
                    _solution = nil
                    _geminiRequested = false
                    _claudeInFlight = false
                    _scansSinceTextStable = 0
                    _lastQuestionTextLength = 0
                    _missingLines = []
                    _deleteMarkers = []
                    _typedCount = 0
                    _currentRound = 1
                    _lastCodingQuestionHash = ""
                    _questionText = ""
                    _mcqRequested = false
                    _mcqAnswer = nil
                    _lastMCQQuestionHash = ""
                    // Clear ALL caches so stale answers don't persist
                    _mcqAnswerCache.removeAll()
                    _codingSolutionCache.removeAll()
                    try? FileManager.default.removeItem(atPath: resetPath)
                    try? FileManager.default.removeItem(atPath: "/tmp/ccsv_solution_lines.txt")
                    _needsVisualReset = true  // tell main loop to reset VLM bounds + clear overlay
                    NSLog("ContentState: FULL RESET via flag file (caches cleared, question flow restarting)")
                }

                // Only accumulate from BOUNDED scans (after VLM established bounds)
                // Full scans include Chrome toolbar noise that pollutes the accumulator
                let visibleLines = q.lines.map { $0.text }
                latestVisibleLines = visibleLines
                let isBounded = _questionBounds != .zero
                if isBounded {
                    questionAccumulator.feed(visibleLines: visibleLines, quality: ScrollAccumulator.qualityBounded)
                }
                // Evaluate scroll signal
                questionScrollSignal.evaluate(
                    visibleLines: visibleLines,
                    panelBounds: q.bounds,
                    lineHeight: q.lineHeight > 0 ? q.lineHeight : 28
                )
                // Use accumulated text for solution matching (more complete).
                // For MCQ: if accumulator is empty (bounds not yet set), use visible lines directly.
                // MCQ questions usually fit on one screen — no scrolling needed.
                if questionAccumulator.fullText.isEmpty && !visibleLines.isEmpty {
                    _questionText = visibleLines.joined(separator: "\n")
                } else {
                    _questionText = questionAccumulator.fullText
                }
                // Only update bounds from bounded scans — VLM sets initial bounds
                if isBounded {
                    _questionBounds = q.bounds
                }

                // Evaluate horizontal scroll signal (sub-panel truncation)
                if isBounded {
                    hScrollSignal.evaluate(visibleLines: q.lines, panelBounds: q.bounds)

                    // If horizontal content just changed, try to extend truncated lines
                    if hScrollSignal.justCaptured {
                        var extended = false
                        for line in q.lines {
                            if questionAccumulator.extendLine(withText: line.text) {
                                extended = true
                            }
                        }
                        if extended {
                            _questionText = questionAccumulator.fullText
                        }
                    }

                    // Write signal file for external test harness (append-only — never delete
                    // during a session, so the harness can pick it up even after scroll moves past)
                    let hscrollPath = "/tmp/ccsv_hscroll_needed"
                    if hScrollSignal.needsScrollRight, let sp = hScrollSignal.subPanelBounds {
                        let info = "\(Int(sp.minX)) \(Int(sp.minY)) \(Int(sp.width)) \(Int(sp.height))"
                        try? info.write(toFile: hscrollPath, atomically: true, encoding: .utf8)
                    }
                }

                // Log accumulation progress
                NSLog("ContentState: accumulated %d lines, %d chars, scroll=%@/%@, captured=%@/%@",
                      questionAccumulator.accumulatedLines.count,
                      _questionText.count,
                      questionScrollSignal.needsScrollDown ? "▼" : "—",
                      hScrollSignal.needsScrollRight ? "▶" : "—",
                      questionScrollSignal.justCaptured ? "✓" : "—",
                      hScrollSignal.justCaptured ? "✓" : "—")

                // Dump accumulated text to file — LINE-BY-LINE for proper comparison
                let lineText = questionAccumulator.accumulatedLines.joined(separator: "\n")
                if let data = lineText.data(using: .utf8) {
                    try? data.write(to: URL(fileURLWithPath: "/tmp/ccsv_accumulated_text.txt"))
                }
            }

            if let e = scan.editorPanel {
                _editorLines = e.lines
                _editorBounds = e.bounds
                _lineHeight = e.lineHeight
            }

            // Detect question type via two signals:
            // 1. "Compiler Output" / "Compile And Run" / "Run Tests" in OCR text
            // 2. Code structure in editor panel (braces, semicolons, class/function declarations)
            // Signal 2 is needed because "Compiler Output" is in the footer area,
            // outside VLM panel bounds — bounded scans never capture it.
            let allTexts = (_editorLines.map { $0.text } + (scan.questionPanel?.lines.map { $0.text } ?? []))
                .joined(separator: " ")
            let hasCompilerUI = allTexts.contains("Compiler Output") || allTexts.contains("Compile And Run")
                || allTexts.contains("Run Tests")
            // Secondary: editor lines contain code structure (class, braces, semicolons)
            let editorText = _editorLines.map { $0.text }.joined(separator: " ")
            let codeSignals = ["{", "}", ";", "class ", "function ", "import ", "@Override",
                               "@SpringBoot", "@RestController", "@Autowired", "public ", "private "]
            let codeSignalCount = codeSignals.filter { editorText.contains($0) }.count
            let hasCodeEditor = codeSignalCount >= 2 && _editorLines.count >= 3
            let prevType = _questionType
            let detected: QuestionType = (hasCompilerUI || hasCodeEditor) ? .coding : .mcq
            // Lock: once Claude was called for this type, don't flip (usually).
            // Exception: allow MCQ→CODING flip if we have strong code evidence,
            // because the initial scan often misdetects coding as MCQ (footer text
            // "Compiler Output" is outside VLM bounds).
            if _geminiRequested && prevType == .coding && detected == .mcq {
                // Stay as coding — Compiler Output may scroll off screen temporarily
            } else if _mcqRequested && prevType == .mcq && detected == .coding && !hasCodeEditor {
                // Stay as MCQ — weak signal (just "Run Tests" text, could be noise)
            } else {
                _questionType = detected
            }

            if _questionType != prevType {
                NSLog("ContentState: question type changed → %@", _questionType == .mcq ? "MCQ" : "CODING")
                if _questionType == .mcq {
                    _mcqRequested = false  // reset so Gemini can be asked for new MCQ
                    _mcqAnswer = nil
                }
            }

            // MCQ: detect question change — reset if visible question text changed significantly.
            // Uses VISIBLE lines (current scan) for same reason as coding detection above.
            if _questionType == .mcq {
                let currentHash = String(latestVisibleLines.joined(separator: " ").prefix(60))
                if currentHash != _lastMCQQuestionHash && !currentHash.isEmpty {
                    if _mcqRequested {
                        _needsVisualReset = true
                        NSLog("ContentState: MCQ question CHANGED — resetting for new question")
                        questionAccumulator.reset()
                        _questionText = ""
                    }
                    _lastMCQQuestionHash = currentHash

                    // Check answer cache first — instant recall for previously answered questions
                    if let cached = _mcqAnswerCache[currentHash] {
                        NSLog("ContentState: MCQ cache HIT → %@ (no Claude call needed)", cached.letters)
                        _mcqAnswer = cached
                        _mcqRequested = true  // Already have answer, don't re-request
                    } else {
                        _mcqRequested = false
                        _mcqAnswer = nil
                    }
                }
            }

            // MCQ: ask Claude CLI for answer
            // The question text (from scroll accumulator) contains BOTH the question AND the answer options.
            // Detect single-answer (radio buttons) vs multi-answer (checkboxes) from text cues.
            // MCQ: require at least 20 chars of question text. Short questions like
            // "What does @Transactional do?" are only ~30 chars. The old 100-char threshold
            // caused short MCQs to never trigger Claude.
            if _questionType == .mcq && !_mcqRequested && _questionText.count > 20 {
                _mcqRequested = true
                let questionSnapshot = _questionText

                // Detect multi-answer from visual/text cues:
                // - "Select all" / "select all that apply" / "choose all" → multiple
                // - Checkboxes (□) → multiple
                // - Default → single answer (radio buttons)
                let lower = questionSnapshot.lowercased()
                let isMultiAnswer = lower.contains("select all") || lower.contains("choose all")
                    || lower.contains("all that apply") || lower.contains("more than one")
                    || lower.contains("multiple correct") || lower.contains("□")

                // MCQ answer options are in the editor/answer panel (right side),
                // NOT in the question panel. Include them if available.
                // Filter out short UI chrome (buttons like "Submit", headers) — keep option text.
                let optionsSnapshot: String
                let optionCandidates = _editorLines
                    .map { $0.text.trimmingCharacters(in: .whitespaces) }
                    .filter { $0.count > 5 }  // skip short UI labels
                if !optionCandidates.isEmpty {
                    optionsSnapshot = "Answer options:\n" + optionCandidates.joined(separator: "\n")
                    NSLog("ContentState: MCQ options from editor panel (%d lines): %@",
                          optionCandidates.count, String(optionCandidates.joined(separator: " | ").prefix(200)))
                } else {
                    optionsSnapshot = "(Answer options may be embedded in the question text above)"
                }

                let choiceHint = isMultiAnswer
                    ? "This is a MULTIPLE CHOICE question — there may be MORE THAN ONE correct answer. Select ALL that apply."
                    : "This is a SINGLE CHOICE question — select exactly ONE answer."

                NSLog("ContentState: asking Claude CLI for MCQ answer (%d chars, multi=%@)",
                      questionSnapshot.count, isMultiAnswer ? "YES" : "NO")

                DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                    let answer = ClaudeSolver.solve(
                        question: questionSnapshot,
                        options: optionsSnapshot,
                        choiceHint: choiceHint
                    )
                    if let answer = answer {
                        self?.setMCQAnswer(answer)
                    } else {
                        NSLog("ContentState: Claude MCQ returned nil — will retry on next scan")
                        // Reset so next scan cycle can retry with fresh/updated question text
                        self?.queue.sync { self?._mcqRequested = false }
                    }
                }
            }

            // Coding: detect question change — reset if visible question text changed significantly.
            // Uses VISIBLE lines (current scan), not accumulated text, because the accumulator
            // prepends old text — prefix(60) would never change when switching questions.
            if _questionType == .coding {
                let visibleHash = String(latestVisibleLines.joined(separator: " ").prefix(60))
                if visibleHash != _lastCodingQuestionHash && !visibleHash.isEmpty {
                    if _solution != nil {
                        // We had a solution for the old question — cache it and reset
                        _needsVisualReset = true
                        NSLog("ContentState: CODING question CHANGED — resetting for new question")
                        if !_lastCodingQuestionHash.isEmpty {
                            _codingSolutionCache[_lastCodingQuestionHash] = _solution
                        }
                        questionAccumulator.reset()
                        _questionText = ""
                        _solution = nil
                        _geminiRequested = false
                        _scansSinceTextStable = 0
                        _lastQuestionTextLength = 0
                        _missingLines = []
                        _deleteMarkers = []
                        _typedCount = 0
                        _currentRound = 1
                        _previousTypedCount = 0
                        _lastTypedConfirmation = nil
                        // NOTE: Do NOT delete /tmp/ccsv_solution_lines.txt here.
                        // This hash-change fires too aggressively (auto-scroll changes visible text).
                        // HP handles stale solutions via its own question-change detection.
                        // Only the external reset flag path (/tmp/ccsv_reset_flag) deletes the file.
                    }
                    _lastCodingQuestionHash = visibleHash

                    // Check solution cache — instant recall for previously visited coding questions
                    if let cached = _codingSolutionCache[visibleHash] {
                        NSLog("ContentState: CODING cache HIT → '%@' (no Claude call needed)", cached.problemId)
                        _solution = cached
                        _geminiRequested = true  // Already have solution, don't re-request
                    }
                }
            }

            // Claude CLI only — no MockSolutions keyword matching.
            // Wait for scroll accumulator to finish collecting before sending to Claude.
            // Send when: (a) scroll done (no ▼), OR (b) text hasn't grown for 5+ scans (scroll stalled/nobody scrolled).
            if _solution == nil && !_questionText.isEmpty && _questionType != .mcq {
                let hasEnoughText = _questionText.count > 80
                // Track text stability — if text stops growing, scroll may be stalled
                if _questionText.count > _lastQuestionTextLength {
                    _scansSinceTextStable = 0
                    _lastQuestionTextLength = _questionText.count
                } else {
                    _scansSinceTextStable += 1
                }
                let scrollDone = !questionScrollSignal.needsScrollDown
                let scrollStalled = _scansSinceTextStable >= 5  // ~10s at 2s/scan
                let readyToSend = scrollDone || scrollStalled
                if !_geminiRequested && hasEnoughText && readyToSend {
                    if scrollStalled && !scrollDone {
                        NSLog("ContentState: scroll stalled (%d scans stable) — sending partial question to Claude CLI", _scansSinceTextStable)
                    }
                    _geminiRequested = true
                    let questionSnapshot = _questionText
                    let editorSnapshot = _editorLines.map { $0.text }.joined(separator: "\n")
                    _claudeInFlight = true
                    NSLog("ContentState: asking Claude CLI for coding solution (%d chars, %d editor lines)",
                          questionSnapshot.count, _editorLines.count)

                    DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                        defer { self?.queue.sync { self?._claudeInFlight = false } }
                        if let code = ClaudeSolver.solveCoding(question: questionSnapshot, editorCode: editorSnapshot) {
                            let solution = GeminiClient.parseCodeToSolution(code: code, questionText: questionSnapshot)
                            self?.setGeminiSolution(solution)
                        } else {
                            NSLog("ContentState: Claude coding returned nil")
                        }
                    }
                } else if !_geminiRequested {
                    // Waiting for enough question text (need >80 chars)
                }
            }

            // Compute missing lines
            if let sol = _solution {
                _computeMissingLines(solution: sol)
            }
        }
    }

    /// Set a Gemini-generated solution (thread-safe, called from async callback)
    func setGeminiSolution(_ solution: MockSolution) {
        queue.sync {
            guard _solution == nil else {
                NSLog("ContentState: Gemini solution arrived but MockSolution already matched — ignoring")
                return
            }
            _solution = solution
            NSLog("ContentState: GEMINI solution set '%@' (%d lines)", solution.problemId, solution.lines.count)
            _computeMissingLines(solution: solution)
        }
    }

    /// Reset Gemini state (e.g., when problem changes)
    func resetGeminiState() {
        queue.sync {
            _geminiRequested = false
        }
    }

    /// Platform-specific class patterns for fold detection — set at startup
    var templateClassPatterns: [String] = ["public class Solution", "class Solution"]

    var needsSuperDeepScan = false

    /// Update editor content from DeepScan result (thread-safe)
    func updateEditor(lines: [DetectedLine], lineHeight: CGFloat) {
        queue.sync {
            _editorLines = lines
            _lineHeight = lineHeight
        }
    }

    /// Update from LLM super-deep scan analysis (thread-safe)
    func updateFromLLM(_ analysis: ScreenAnalysis) {
        queue.sync {
            _questionBounds = analysis.questionPanel.bounds
            _editorBounds = analysis.editorPanel.bounds
            _questionText = analysis.questionPanel.content
            _solution = analysis.solution

            if analysis.editorPanel.lineHeight > 0 {
                _lineHeight = analysis.editorPanel.lineHeight
            }

            let currentCode = analysis.editorPanel.content
            let codeLines = currentCode.components(separatedBy: "\n")
            let startY = analysis.editorPanel.firstLineY > 0 ? analysis.editorPanel.firstLineY : _editorBounds.minY + 10
            let codeX = _editorBounds.minX + 50

            _editorLines = codeLines.enumerated().map { (i, text) in
                DetectedLine(
                    text: text,
                    bounds: CGRect(x: codeX,
                                   y: startY + CGFloat(i) * _lineHeight,
                                   width: _editorBounds.width - 70,
                                   height: _lineHeight)
                )
            }

            NSLog("ContentState: LLM update — editor %d lines, lineHeight=%.0f, startY=%.0f",
                  _editorLines.count, _lineHeight, startY)

            if let sol = _solution {
                _computeMissingLines(solution: sol)
            }
        }
    }

    /// Public wrapper for recomputing missing lines (thread-safe)
    func recomputeMissing(solution: MockSolution) {
        queue.sync { _computeMissingLines(solution: solution) }
    }

    /// Compute which solution lines are missing — MUST be called inside queue.sync
    private func _computeMissingLines(solution: MockSolution) {
        let editorTexts = _editorLines.map { $0.text }
        var consumed = [Bool](repeating: false, count: editorTexts.count)

        var typed = Set<Int>()
        var missing: [MissingLine] = []
        var toDelete: [MissingLine] = []  // lines with action = .delete (comments to remove)

        for (si, solLine) in solution.lines.enumerated() {
            let solText = solLine.text.trimmingCharacters(in: .whitespaces)
            guard !solText.isEmpty else { continue }

            var matched = false
            for (ei, editorText) in editorTexts.enumerated() {
                guard !consumed[ei] else { continue }
                if fuzzyMatch(editorText, solText) {
                    consumed[ei] = true
                    typed.insert(si)
                    matched = true
                    // If this line's action is .delete, track it for the human player
                    if solLine.action == .delete {
                        toDelete.append(MissingLine(
                            solutionIndex: si,
                            text: solLine.text,
                            insertAfterY: _editorLines[ei].bounds.midY,
                            lineType: "delete",
                            section: solLine.section
                        ))
                    }
                    break
                }
            }

            if !matched {
                // Only add to missing if it's a .type or .keep action (not .delete that wasn't found)
                if solLine.action == .type {
                    let insertY = findInsertionY(solutionIndex: si, typed: typed)
                    missing.append(MissingLine(
                        solutionIndex: si,
                        text: solLine.text,
                        insertAfterY: insertY,
                        lineType: solLine.type,
                        section: solLine.section
                    ))
                }
                // .keep lines that aren't found are template (possibly folded) — handled below
                // .delete lines that aren't found are already removed — nothing to do
            }
        }

        // --- Fold detection ---
        // If round 1 has many .keep lines but very few matched, template is likely folded.
        // Auto-advance to round 2 so we show the lines the user needs to TYPE.
        let round1KeepLines = solution.lines.filter { $0.round == 1 && $0.action == .keep && !$0.text.trimmingCharacters(in: .whitespaces).isEmpty }
        let round1Matched = round1KeepLines.filter { line in typed.contains(solution.lines.firstIndex(where: { $0.text == line.text }) ?? -1) }.count
        let foldDetected = _currentRound == 1
            && round1KeepLines.count > 3
            && round1Matched < round1KeepLines.count / 2
            && _editorLines.count < round1KeepLines.count
        if foldDetected {
            // Check we at least see the class signature (proves it's a real editor, not garbage)
            let hasClassSig = editorTexts.contains { edText in
                self.templateClassPatterns.contains { fuzzyMatch(edText, $0) }
            }
            if hasClassSig {
                _currentRound = 2
                NSLog("ContentState: FOLD detected (matched %d/%d round-1 lines, editor has %d lines) — skipping to Round 2",
                      round1Matched, round1KeepLines.count, _editorLines.count)
            }
        }

        // Detect newly typed line — trigger confirmation flash
        if typed.count > _previousTypedCount && _previousTypedCount > 0 {
            if let lastMissingText = _missingLines.first?.text.trimmingCharacters(in: .whitespaces),
               let matchedEditorLine = _editorLines.first(where: { fuzzyMatch($0.text, lastMissingText) }) {
                _lastTypedConfirmation = TypedConfirmation(y: matchedEditorLine.bounds.midY, timestamp: Date())
                NSLog("ContentState: ✓ line typed — confirmation at Y=%.0f", matchedEditorLine.bounds.midY)
            }
        }
        _previousTypedCount = typed.count
        _typedCount = typed.count

        // Compute total rounds
        _totalRounds = solution.lines.map { $0.round }.max() ?? 1

        // Filter missing to current round only
        let currentRoundMissing = missing.filter { ml in
            solution.lines[ml.solutionIndex].round == _currentRound
        }

        // Auto-advance: if all .type lines in current round are typed, go to next round
        if currentRoundMissing.isEmpty && _currentRound < _totalRounds {
            _currentRound += 1
            NSLog("ContentState: ▶ Advanced to Round %d/%d", _currentRound, _totalRounds)
            let newRoundMissing = missing.filter { ml in
                solution.lines[ml.solutionIndex].round == _currentRound
            }
            _missingLines = newRoundMissing
        } else {
            _missingLines = currentRoundMissing
        }

        // Store delete markers for GhostLayout and signal file
        _deleteMarkers = toDelete

        NSLog("ContentState: %d/%d typed, %d missing, %d to-delete (round %d/%d)",
              _typedCount, solution.lines.count, _missingLines.count, toDelete.count, _currentRound, _totalRounds)

        // Diagnostic: log editor lines and missing (compact)
        if _typedCount < solution.lines.count {
            let editorSample = _editorLines.prefix(8).enumerated().map { (i, l) in
                "[\(i)]'\(l.text.prefix(30))' y=\(Int(l.bounds.midY))"
            }.joined(separator: " | ")
            NSLog("ContentState: EDITOR(%d): %@", _editorLines.count, editorSample)
            let missingSample = _missingLines.prefix(3).map { "[\($0.solutionIndex)]='\($0.text.prefix(35))'" }.joined(separator: ", ")
            NSLog("ContentState: MISSING: %@", missingSample)
            if !toDelete.isEmpty {
                let delSample = toDelete.map { "'\($0.text.prefix(30))' y=\(Int($0.insertAfterY))" }.joined(separator: ", ")
                NSLog("ContentState: DELETE: %@", delSample)
            }
        }

        // Write structured signal file for human player
        _writeSignalFile(solution: solution)
    }

    /// Find the Y position where a ghost line should be inserted
    private func findInsertionY(solutionIndex: Int, typed: Set<Int>) -> CGFloat {
        // Look backwards from solutionIndex for the nearest typed line
        for i in stride(from: solutionIndex - 1, through: 0, by: -1) {
            if typed.contains(i) {
                // Find this typed line's Y position in the editor
                if let solText = _solution?.lines[i].text.trimmingCharacters(in: .whitespaces),
                   let editorLine = _editorLines.first(where: { fuzzyMatch($0.text, solText) }) {
                    return editorLine.bounds.midY
                }
            }
        }

        // No preceding typed line found — use the last real code line visible in the editor.
        // This avoids returning editorBounds.minY which lands on the toolbar/tabs area.
        let codeLines = _editorLines
            .filter { !$0.text.trimmingCharacters(in: .whitespaces).isEmpty }
            .filter { $0.bounds.midY >= _editorBounds.minY && $0.bounds.midY <= _editorBounds.maxY - 50 }
            .sorted { $0.bounds.midY < $1.bounds.midY }

        // Find a line containing an opening brace (method body start) to insert after
        if let braceLineY = codeLines.last(where: {
            $0.text.contains("{") && $0.bounds.midY < _editorBounds.midY
        })?.bounds.midY {
            return braceLineY
        }

        // Fallback: last code line in top half of editor
        if let lastCodeY = codeLines.filter({ $0.bounds.midY < _editorBounds.midY }).last?.bounds.midY {
            return lastCodeY
        }

        // Ultimate fallback: skip toolbar area (at least 2 line heights below top)
        return _editorBounds.minY + _lineHeight * 3
    }

    /// Fuzzy match using shared Levenshtein-based matcher
    private func fuzzyMatch(_ detected: String, _ solution: String) -> Bool {
        FuzzyMatch.matches(detected, solution)
    }

    /// Write structured JSON signal file for the human player (DEBUG ONLY).
    /// Disabled by default. Enable with env var GHOST_DEBUG_SIGNAL=1.
    /// The HumanPlayer process should use visual signals from the overlay frame,
    /// not this file — per CCSV channel separation principle.
    private func _writeSignalFile(solution: MockSolution) {
        // Only write when debug mode enabled
        guard ProcessInfo.processInfo.environment["GHOST_DEBUG_SIGNAL"] == "1" else { return }
        // Skip when editor bounds are invalid — prevents JSON crash on infinite values
        guard _editorBounds.width > 0 && _editorBounds.height > 0 else { return }

        var signal: [String: Any] = [
            "timestamp": CFAbsoluteTimeGetCurrent(),
            "typed": _typedCount,
            "total": solution.lines.count,
            "round": _currentRound,
            "totalRounds": _totalRounds,
            "editorBounds": [
                "x": _editorBounds.minX, "y": _editorBounds.minY,
                "w": _editorBounds.width, "h": _editorBounds.height
            ],
            "lineHeight": _lineHeight
        ]

        // Next action: first delete marker, or first missing line to type
        if let del = _deleteMarkers.first {
            signal["nextAction"] = [
                "type": "delete",
                "text": del.text,
                "y": del.insertAfterY
            ] as [String: Any]
        } else if let ins = _missingLines.first {
            signal["nextAction"] = [
                "type": "type",
                "text": ins.text,
                "y": ins.insertAfterY
            ] as [String: Any]
        } else {
            signal["nextAction"] = ["type": "done"] as [String: Any]
        }

        // Insert marker (the line the human should type next)
        if let ins = _missingLines.first {
            signal["insertMarker"] = [
                "text": ins.text,
                "y": ins.insertAfterY,
                "solutionIndex": ins.solutionIndex
            ] as [String: Any]
        }

        // Delete markers (comments to remove)
        signal["deleteMarkers"] = _deleteMarkers.map { del in
            ["text": del.text, "y": del.insertAfterY] as [String: Any]
        }

        // Missing lines (all of them)
        signal["missingLines"] = _missingLines.map { ml in
            ["text": ml.text, "y": ml.insertAfterY, "index": ml.solutionIndex] as [String: Any]
        }

        // Write atomically
        if let data = try? JSONSerialization.data(withJSONObject: signal, options: .prettyPrinted) {
            let tmpPath = "/tmp/ccsv_human_signal.tmp"
            let finalPath = "/tmp/ccsv_human_signal.json"
            try? data.write(to: URL(fileURLWithPath: tmpPath))
            try? FileManager.default.removeItem(atPath: finalPath)
            try? FileManager.default.moveItem(atPath: tmpPath, toPath: finalPath)
        }
    }
}

struct MissingLine {
    let solutionIndex: Int
    let text: String
    let insertAfterY: CGFloat
    let lineType: String       // "key", "ctx", "boiler"
    let section: String        // "input", "logic", "output"
}
