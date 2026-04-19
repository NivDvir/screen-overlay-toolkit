import AppKit
import Vision

// Redirect stdout/stderr to log file so logs are captured even when launched via double-click
if let logFile = fopen("/tmp/ccsv_overlay.log", "w") {
    dup2(fileno(logFile), STDOUT_FILENO)
    dup2(fileno(logFile), STDERR_FILENO)
    fclose(logFile)
}

// Prevent App Nap from throttling GPU compute (VLM inference goes 20x slower with App Nap)
let _ = ProcessInfo.processInfo.beginActivity(
    options: [.userInitiated, .latencyCritical, .idleSystemSleepDisabled],
    reason: "GPU VLM inference requires full compute performance"
)


@available(macOS, deprecated: 14.0)
func captureScreen() -> CGImage? {
    CGWindowListCreateImage(CGRect.infinite, .optionOnScreenOnly, kCGNullWindowID, [.bestResolution])
}

/// Capture screen EXCLUDING a specific window (e.g. the overlay)
@available(macOS, deprecated: 14.0)
func captureScreenExcluding(windowID: CGWindowID) -> CGImage? {
    // Capture everything below the specified window (excludes it and anything above)
    CGWindowListCreateImage(CGRect.infinite, .optionOnScreenBelowWindow, windowID, [.bestResolution])
}

let app = NSApplication.shared
app.setActivationPolicy(.accessory)  // menu-bar app: no dock icon

// Clean up temp files on exit (SIGINT/SIGTERM)
func cleanupTempFiles() {
    let files = ["/tmp/ccsv_solution_lines.txt", "/tmp/ccsv_overlay_frame.png",
                 "/tmp/ccsv_accumulated_text.txt", "/tmp/ccsv_overlay.log",
                 "/tmp/ccsv_question_crop.png", "/tmp/ccsv_question_enhanced.png",
                 "/tmp/ccsv_reset_flag",
                 "/tmp/ccsv_ocr_dump.txt"]
    for f in files { try? FileManager.default.removeItem(atPath: f) }
    NSLog("GroundingKit: temp files cleaned")
}
signal(SIGINT) { _ in cleanupTempFiles(); exit(0) }
signal(SIGTERM) { _ in cleanupTempFiles(); exit(0) }

let overlay = OverlayController()
overlay.setStatus("⏳ Starting...")

guard let image = captureScreen() else { exit(1) }

if #available(macOS 26.0, *) {
    let detector = NativePanelDetector()
    let state = ContentState()

    // Detect platform and inject config into all components
    let platform = PlatformConfig.detect()
    NSLog("GroundingKit: Platform = %@ (editorDark=%@)", platform.name, platform.editorThemeIsDark ? "yes" : "no")
    ChromeCapture.windowKeywords = platform.browserWindowKeywords
    DeepScanner.sidebarLabels = platform.sidebarLabels
    DeepScanner.editorThemeIsDark = platform.editorThemeIsDark
    GhostLayout.uiKeywords = platform.uiKeywords
    GeminiClient.shared.promptIOHint = platform.promptIOHint
    state.templateClassPatterns = platform.templateClassPatterns
    overlay.setStatus("Platform: \(platform.name)")

    // Load VLM in background — doesn't block
    Task.detached {
        await MainActor.run { overlay.setStatus("Loading VLM model...") }
        do {
            try await detector.loadModel()
            await MainActor.run { overlay.setStatus("✅ VLM loaded — detecting...") }
        } catch {
            NSLog("NativeVLM: LOAD ERROR: %@", "\(error)")
            await MainActor.run { overlay.setStatus("❌ VLM: \(error.localizedDescription)") }
        }
    }

    // Initial deep scan for content only — no panel boxes (VLM handles those)
    Task {
        let scan = await DeepScanner.scanFull(image: image)
        state.update(from: scan)
        await MainActor.run {
            overlay.setStatus("🔍 Deep scan done — waiting for VLM panels...")
        }
    }

    // Continuous 7-cycle routine:
    //   Cycle 1: VLM scan (high-rank — finds panel boundaries)
    //   Cycles 2-7: DeepScan (low-rank — maps content within VLM-found boundaries)
    // DeepScans wait for at least one successful VLM before scanning with bounds.

    // DIAGNOSTIC: set true to hide all overlay rendering (keeps window alive for capture exclusion test)
    let diagnosticHideOverlay = false

    var cycleCount = 0
    var roundCount = 0          // which 7-cycle round we're in
    var scanInProgress = false
    var vlmRunning = false
    var vlmSucceeded = false
    let pixelDiff = PixelDiff()

    detector.onProgress = { detail in
        overlay.setStatusSegments([
            StatusSegment(text: "R\(roundCount) ", color: "white"),
            StatusSegment(text: "│ ", color: "gray"),
            StatusSegment(text: "VLM ", color: "yellow"),
            StatusSegment(text: "│ ", color: "gray"),
            StatusSegment(text: detail, color: "yellow"),
        ])
    }

    /// Build status segments: R# | type | details  (outer → inner, left to right)
    func setStatusSegments(round: Int, isVLM: Bool, detail: String) {
        let segs: [StatusSegment] = [
            StatusSegment(text: "R\(round) ", color: "white"),
            StatusSegment(text: "│ ", color: "gray"),
            StatusSegment(text: isVLM ? "VLM " : "Scan ", color: isVLM ? "yellow" : "cyan"),
            StatusSegment(text: "│ ", color: "gray"),
            StatusSegment(text: detail, color: isVLM ? "yellow" : "white"),
        ]
        overlay.setStatusSegments(segs)
    }

    Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { _ in
        guard !scanInProgress else { return }
        scanInProgress = true
        cycleCount += 1
        let cycleInRound = ((cycleCount - 1) % 7) + 1  // 1-7
        if cycleInRound == 1 { roundCount += 1 }

        Task {
            defer { scanInProgress = false }

            // Capture screen (excluding overlay)
            var img: CGImage?
            let testImagePath = "/tmp/vlm_test_image.png"
            if FileManager.default.fileExists(atPath: testImagePath),
               let src = CGImageSourceCreateWithURL(URL(fileURLWithPath: testImagePath) as CFURL, nil),
               let testCG = CGImageSourceCreateImageAtIndex(src, 0, nil) {
                img = testCG
            } else {
                // Capture screen excluding overlay — coordinates match VLM bounds (screen-relative)
                autoreleasepool { img = captureScreenExcluding(windowID: CGWindowID(overlay.windowNumber)) }
            }
            guard let capturedImg = img else { return }

            // VLM scan frequency adapts to round number:
            //   Round 1: cycles 1, 3, 5 (3/7) — fast panel lock-in after startup
            //   Round 2: cycles 1, 4     (2/7) — refinement
            //   Round 3+: cycle 1 only   (1/7) — steady state
            let shouldRunVLM: Bool
            if roundCount == 1 {
                shouldRunVLM = [1, 3, 5].contains(cycleInRound)
            } else if roundCount == 2 {
                shouldRunVLM = [1, 4].contains(cycleInRound)
            } else {
                shouldRunVLM = cycleInRound == 1
            }
            if shouldRunVLM && !vlmRunning {
                vlmRunning = true
                let vlmImage = capturedImg
                let rnd = roundCount
                await MainActor.run { setStatusSegments(round: rnd, isVLM: true, detail: "processing...") }

                Task.detached {
                    if let analysis = await detector.detectPanels(from: vlmImage) {
                        // Lock bounds after first stable VLM run.
                        // VLM bbox estimates fluctuate wildly between runs
                        // (e.g. 820px wide vs 634px wide for same panel).
                        // Using a narrow bbox crops text and produces truncated
                        // duplicates that poison the accumulator.
                        //
                        // CLAMP to Chrome window bounds — VLM sometimes extends
                        // editor bounds past Chrome into desktop/Finder content.
                        let oldQ = state.questionBounds
                        let rawQ = analysis.questionPanel.bounds
                        let rawE = analysis.editorPanel.bounds
                        let newQ = ChromeCapture.clampToChrome(rawQ)
                        let newE = ChromeCapture.clampToChrome(rawE)
                        if newQ != rawQ || newE != rawE {
                            NSLog("NativeVLM: CLAMPED to Chrome — Q %.0fx%.0f→%.0fx%.0f, E %.0fx%.0f→%.0fx%.0f",
                                  rawQ.width, rawQ.height, newQ.width, newQ.height,
                                  rawE.width, rawE.height, newE.width, newE.height)
                        }
                        // Sanity check: reject bounds that are obviously wrong.
                        // Question panel: 20-70% of screen width.
                        // MCQ questions have wider question panels (60%+) since there's no code editor.
                        let screenW = NSScreen.main?.frame.width ?? 1800
                        let qWidthRatio = newQ.width / screenW
                        if qWidthRatio < 0.20 || qWidthRatio > 0.70 {
                            NSLog("NativeVLM: REJECTED — Q width ratio %.0f%% out of range (20-70%%)", qWidthRatio * 100)
                            vlmRunning = false
                            return
                        }

                        if oldQ == .zero {
                            // First VLM run — accept bounds
                            state.questionBounds = newQ
                            state.editorBounds = newE
                            NSLog("NativeVLM: initial bounds Q=%.0fx%.0f E=%.0fx%.0f",
                                  newQ.width, newQ.height,
                                  newE.width, newE.height)
                        } else if abs(oldQ.width - newQ.width) < 100 &&
                                  abs(oldQ.height - newQ.height) < 100 {
                            // Stable — bounds similar to locked, accept update
                            state.questionBounds = newQ
                            state.editorBounds = newE
                        } else if state.editorLines.count < 10 {
                            // Current bounds produce very few editor lines → accept correction.
                            // The first VLM run may have given bad bounds; allow recovery.
                            state.questionBounds = newQ
                            state.editorBounds = newE
                            NSLog("NativeVLM: CORRECTED bounds (editor had %d lines) Q=%.0fx%.0f E=%.0fx%.0f",
                                  state.editorLines.count, newQ.width, newQ.height, newE.width, newE.height)
                        } else {
                            // Unstable — VLM gave wildly different bounds, IGNORE
                            NSLog("NativeVLM: REJECTED bounds (%.0fx%.0f vs locked %.0fx%.0f)",
                                  newQ.width, newQ.height, oldQ.width, oldQ.height)
                        }
                        vlmSucceeded = true
                        pixelDiff.reset()
                        state.questionScrollSignal.reset()
                        await MainActor.run {
                            overlay.clear()
                            overlay.showPanel(PanelRect(x: state.questionBounds.minX, y: state.questionBounds.minY,
                                                        width: state.questionBounds.width, height: state.questionBounds.height,
                                                        label: "QUESTION", paragraphCount: 0), color: "blue", label: "QUESTION")
                            overlay.showPanel(PanelRect(x: state.editorBounds.minX, y: state.editorBounds.minY,
                                                        width: state.editorBounds.width, height: state.editorBounds.height,
                                                        label: "EDITOR", paragraphCount: 0), color: "green", label: "EDITOR")
                            setStatusSegments(round: rnd, isVLM: true, detail: "done ✓")
                        }
                    } else {
                        await MainActor.run {
                            setStatusSegments(round: rnd, isVLM: true, detail: "failed ✗")
                        }
                    }
                    vlmRunning = false
                }
                return
            }

            // Check for visual reset (question change or top-left corner)
            // Clears overlay, resets VLM bounds so panels are re-detected for the new question
            if state.consumeVisualReset() {
                vlmSucceeded = false
                state.questionBounds = .zero
                state.editorBounds = .zero
                await MainActor.run {
                    overlay.clear()
                    overlay.showSolutionOnQuestion(code: "", questionBounds: .zero)
                    overlay.showCollectingBoxes([])
                    overlay.setQuestionPanelBlinking(false)
                    overlay.showGhostClues([])
                }
                NSLog("GroundingKit: VISUAL RESET — VLM bounds + overlay cleared, re-detecting panels")
                return  // skip this cycle, VLM will re-detect next round
            }

            // Cycles 2-7: DeepScan (low-rank — uses VLM boundaries)
            let scanNum = cycleInRound - 1  // 1-6
            let rnd = roundCount

            if !vlmSucceeded {
                await MainActor.run { setStatusSegments(round: rnd, isVLM: false, detail: "waiting for VLM...") }
                return
            }

            await MainActor.run { setStatusSegments(round: rnd, isVLM: false, detail: "\(scanNum)/6 scanning...") }

            let scan: ScanResult
            if state.questionBounds != .zero && state.editorBounds != .zero {
                scan = await DeepScanner.scanWithBounds(
                    image: capturedImg,
                    questionBounds: state.questionBounds,
                    editorBounds: state.editorBounds)
            } else {
                scan = await DeepScanner.scanFull(image: capturedImg)
            }

            // Update FULL state from scan (question text + editor lines + solution matching)
            state.update(from: scan)

            // Auto-scroll: if question panel needs scrolling and no solution yet,
            // inject a CGEvent scroll to reveal more text for the accumulator.
            if state.questionScrollSignal.needsScrollDown && state.solution == nil {
                let qb = state.questionBounds
                if qb != .zero {
                    let scrollX = qb.midX
                    let scrollY = qb.midY
                    if let scrollEvent = CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 1, wheel1: -120, wheel2: 0, wheel3: 0) {
                        // Move mouse to question panel center first
                        if let moveEvent = CGEvent(mouseEventSource: nil, mouseType: .mouseMoved, mouseCursorPosition: CGPoint(x: scrollX, y: scrollY), mouseButton: .left) {
                            moveEvent.post(tap: .cghidEventTap)
                        }
                        scrollEvent.post(tap: .cghidEventTap)
                        NSLog("GroundingKit: auto-scroll at (%.0f, %.0f) — accumulator needs more text", scrollX, scrollY)
                    }
                }
            }

            // Route MCQ vs Coding
            let isMCQ = state.questionType == .mcq
            let mode = platform.overlayMode

            // Generate editor-side clues only if stepAdvancement is enabled
            let newClues: [GhostClue]
            if isMCQ {
                newClues = GhostLayout.generateMCQClues(from: state)
            } else if mode.stepAdvancement {
                newClues = GhostLayout.generateClues(from: state)
            } else {
                newClues = []  // stepAdvancement disabled — no editor clues
            }

            await MainActor.run {
                if !diagnosticHideOverlay {
                    overlay.showGhostClues(newClues)
                }

                if isMCQ {
                    // MCQ: same three-stage visual flow as coding.
                    // Stage 1: collecting (red boxes) — before Claude called
                    // Stage 2: blue blinking, NO overlay — Claude in flight
                    // Stage 3: answer overlay displayed
                    if let mcq = state.mcqAnswer {
                        // ═══ STAGE 3: Answer received ═══
                        let display = """
                        ══ ANSWER: \(mcq.letters)  (#\(mcq.numbers))  raw: \(mcq.rawResponse) ══

                        ── Prompt sent to Claude ──
                        \(mcq.questionSent)

                        \(mcq.optionsSent)
                        """
                        overlay.showCollectingBoxes([])
                        overlay.setQuestionPanelBlinking(false)
                        setStatusSegments(round: rnd, isVLM: false, detail: "\(scanNum)/6 · MCQ → \(mcq.letters)")
                        if !diagnosticHideOverlay {
                            overlay.showSolutionOnQuestion(code: display, questionBounds: state.questionBounds)
                        }
                    } else if state.mcqRequested {
                        // ═══ STAGE 2: Claude in flight — blue blinking + red OCR boxes visible ═══
                        overlay.showSolutionOnQuestion(code: "", questionBounds: .zero)
                        // Keep red OCR text boxes visible during Claude wait
                        if vlmSucceeded, let qPanel = scan.questionPanel {
                            let qb = state.questionBounds
                            let boxes = qPanel.lines
                                .filter { $0.bounds.midX >= qb.minX && $0.bounds.midX <= qb.maxX }
                                .filter { $0.bounds.midY >= qb.minY && $0.bounds.midY <= qb.maxY }
                                .map { $0.bounds }
                            overlay.showCollectingBoxes(boxes)
                        }
                        overlay.setQuestionPanelBlinking(true)
                        setStatusSegments(round: rnd, isVLM: false, detail: "\(scanNum)/6 · MCQ waiting for Claude...")
                    } else {
                        // ═══ STAGE 1: Collecting question text ═══
                        setStatusSegments(round: rnd, isVLM: false, detail: "\(scanNum)/6 · MCQ collecting...")
                    }
                } else {
                    // Coding: three-stage visual flow
                    let hasSolution = state.solution != nil
                    let roundInfo = state.totalRounds > 1 ? " R\(state.currentRound)/\(state.totalRounds)" : ""

                    if !diagnosticHideOverlay {
                        if hasSolution && state.questionBounds != .zero {
                            // ═══ STAGE 3: Solution received ═══
                            overlay.showCollectingBoxes([])       // clear red boxes
                            overlay.setQuestionPanelBlinking(false)

                            if mode.coverQuestion {
                                // Cover Question mode: show ALL lines — template in gray, solution in green.
                                // User sees the complete expected editor content.
                                let allLines = state.solution!.lines
                                    .filter { $0.round <= state.currentRound }
                                    .filter { !$0.text.trimmingCharacters(in: .whitespaces).isEmpty }
                                // Build display with color markers: template (gray) vs solution (green)
                                let displayParts = allLines.map { line -> String in
                                    let marker = line.action == .keep ? "  " : "→ "
                                    return marker + line.text
                                }
                                let solutionText = displayParts.joined(separator: "\n")
                                overlay.showSolutionOnQuestion(code: solutionText, questionBounds: state.questionBounds)

                                // Write FULL code to file for HumanPlayer — ALL lines, complete file.
                                // HP does Cmd+A → Delete → types everything from this file.
                                // Template lines prefixed with #T so HP can use same indent.
                                let solFilePath = "/tmp/ccsv_solution_lines.txt"
                                if !FileManager.default.fileExists(atPath: solFilePath) {
                                    let fileLines = allLines.map { line -> String in
                                        line.action == .keep ? "#T \(line.text)" : line.text
                                    }
                                    let fileContent = fileLines.joined(separator: "\n")
                                    try? fileContent.write(toFile: solFilePath, atomically: true, encoding: .utf8)
                                    NSLog("GroundingKit: wrote %d lines (template+solution) to %@", fileLines.count, solFilePath)
                                }
                            } else {
                                overlay.showSolutionOnQuestion(code: "", questionBounds: .zero)
                            }

                            if mode.stepAdvancement {
                                setStatusSegments(round: rnd, isVLM: false, detail: "\(scanNum)/6 · \(newClues.count) clues\(roundInfo)")
                            } else {
                                let typed = state.typedCount
                                let total = state.solution!.lines.filter { $0.round <= state.currentRound && $0.action != .delete }.count
                                setStatusSegments(round: rnd, isVLM: false, detail: "\(scanNum)/6 · \(typed)/\(total)\(roundInfo)")
                            }
                        } else if state.questionBounds != .zero {
                            // No solution yet
                            if state.claudeInFlight {
                                // ═══ STAGE 2: Claude CLI in flight — blue blinking + red OCR boxes ═══
                                overlay.showSolutionOnQuestion(code: "", questionBounds: .zero)
                                // Keep red OCR text boxes visible during Claude wait
                                if vlmSucceeded, let qPanel = scan.questionPanel {
                                    let qb = state.questionBounds
                                    let boxes = qPanel.lines
                                        .filter { $0.bounds.midX >= qb.minX && $0.bounds.midX <= qb.maxX }
                                        .filter { $0.bounds.midY >= qb.minY && $0.bounds.midY <= qb.maxY }
                                        .map { $0.bounds }
                                    overlay.showCollectingBoxes(boxes)
                                }
                                overlay.setQuestionPanelBlinking(true)
                                setStatusSegments(round: rnd, isVLM: false, detail: "\(scanNum)/6 · Waiting for Claude...")
                            } else {
                                // ═══ STAGE 1: Collecting — red boxes around detected text ═══
                                if vlmSucceeded, let qPanel = scan.questionPanel {
                                    let qb = state.questionBounds
                                    let boxes = qPanel.lines
                                        .filter { $0.bounds.midX >= qb.minX && $0.bounds.midX <= qb.maxX }
                                        .filter { $0.bounds.midY >= qb.minY && $0.bounds.midY <= qb.maxY }
                                        .map { $0.bounds }
                                    overlay.showCollectingBoxes(boxes)
                                }
                                overlay.showSolutionOnQuestion(code: "", questionBounds: .zero)
                                overlay.setQuestionPanelBlinking(false)
                                let charCount = state.questionText.count
                                let scrollArrow = state.questionScrollSignal.needsScrollDown ? " ▼" : ""
                                setStatusSegments(round: rnd, isVLM: false, detail: "\(scanNum)/6 · Collecting \(charCount) chars\(scrollArrow)")
                            }
                        }
                    }
                }
            }

            // Export overlay frame for HumanPlayer's "eyes"
            await MainActor.run {
                if let frame = overlay.exportOverlayFrame() {
                    autoreleasepool {
                        let bm = NSBitmapImageRep(cgImage: frame)
                        if let png = bm.representation(using: .png, properties: [:]) {
                            let tmp = "/tmp/ccsv_overlay_frame.tmp"
                            let final_ = "/tmp/ccsv_overlay_frame.png"
                            try? png.write(to: URL(fileURLWithPath: tmp))
                            try? FileManager.default.removeItem(atPath: final_)
                            try? FileManager.default.moveItem(atPath: tmp, toPath: final_)
                        }
                    }
                }
            }

            if cycleCount % 7 == 0 {
                NSLog("Cycle %d (R%d): %d clues, %d/%d typed",
                      cycleCount, roundCount, newClues.count, state.typedCount, state.solution?.lines.count ?? 0)
            }
        }
    }

    // Tier-1: Fast pixel-diff loop (50ms interval) — detects keystrokes between DeepScan cycles
    Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { _ in
        guard vlmSucceeded, !scanInProgress else { return }

        // Configure pixel diff with current editor bounds
        pixelDiff.configure(
            editorBounds: state.editorBounds,
            lineHeight: state.lineHeight,
            overlayWindowID: CGWindowID(overlay.windowNumber)
        )

        if pixelDiff.detectChange() {
            // A line changed — trigger ghost clue refresh from cached state
            let newClues = GhostLayout.generateClues(from: state)
            overlay.showGhostClues(newClues)
        }
    }

    app.finishLaunching()
    RunLoop.main.run()
} else {
    NSLog("Requires macOS 26+")
    exit(1)
}
