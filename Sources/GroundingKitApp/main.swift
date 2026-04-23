import AppKit
import Vision
import GroundingKit

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

/// Find the title (h1-style heading) and body anchors by looking at the
/// SCREEN VIEW — the same grounding substrate the rest of the app uses.
/// Pipeline: VLM (.reader mode) picks the main article column, then
/// Vision-framework OCR inside that column identifies the title as the
/// top-most line with distinctly larger font. Remaining column area
/// below the title is the body anchor. Works on any on-screen content,
/// no DOM / AppleScript access required — matches the same grounding
/// substrate that PR #222 hardened.
///
/// NOTE: `queryWikipediaAnchors` below (kept for reference) uses Chrome\'s
/// DOM to get the exact pixel bounds from the page source. It\'s a TEST
/// ORACLE only — useful for verifying that the VLM + OCR path returns
/// matching rects when the DOM truth is available. Not used in the demo.
/// Cache the one-time VLM .reader detection so per-frame grounding only pays
/// the fast Vision-OCR cost. VLM is 5-15s, OCR is 300-500ms, so caching lets
/// the overlay track scroll in near-real-time (2+ Hz).
actor ContentPanelCache {
    private var panel: CGRect = .zero
    private var lastChrome: CGRect = .zero

    func get(forChrome chrome: CGRect) -> CGRect? {
        if panel != .zero && lastChrome == chrome { return panel }
        return nil
    }
    func set(_ rect: CGRect, forChrome chrome: CGRect) {
        panel = rect
        lastChrome = chrome
    }
    func invalidate() {
        panel = .zero
    }
}
let contentPanelCache = ContentPanelCache()

@available(macOS 26.0, *)
func findTitleAndBodyAnchors(
    screen: CGImage, detector: NativePanelDetector
) async -> (title: CGRect, body: CGRect)? {
    let cycleStart = CFAbsoluteTimeGetCurrent()
    let chrome = ChromeCapture.chromeBounds()
    // Fast path. If we have a cached content panel for the current Chrome
    // window, skip VLM and go straight to OCR.
    var contentPanel: CGRect
    var usedVLM = false
    if let cached = await contentPanelCache.get(forChrome: chrome), cached != .zero {
        contentPanel = cached
    } else {
        // VLM needs to see ONLY the Chrome window, not the whole desktop
        // (with Terminal, Finder, etc.), otherwise its panel detection gets
        // confused by multiple content-like regions. Crop the screen capture
        // to the Chrome window rect. The CGImage is in RETINA pixels but
        // Chrome bounds are in LOGICAL points — convert via the scale factor.
        let retinaScale = CGFloat(screen.width) / (NSScreen.main?.frame.width ?? CGFloat(screen.width))
        let cropRect: CGRect
        if chrome != .zero && retinaScale > 0 {
            cropRect = CGRect(
                x: chrome.minX * retinaScale,
                y: chrome.minY * retinaScale,
                width: chrome.width * retinaScale,
                height: chrome.height * retinaScale
            )
        } else {
            cropRect = CGRect(x: 0, y: 0, width: CGFloat(screen.width), height: CGFloat(screen.height))
        }
        let cropped = screen.cropping(to: cropRect) ?? screen
        guard let analysis = await detector.detectPanels(from: cropped, mode: .reader) else {
            NSLog("findTitleAndBodyAnchors: VLM did not return a content panel")
            return nil
        }
        // VLM output is in the CROPPED image's coord space. Translate back to
        // screen coords by adding the Chrome window origin.
        let croppedPanel = analysis.questionPanel.bounds
        if chrome != .zero {
            contentPanel = CGRect(
                x: croppedPanel.minX + chrome.minX,
                y: croppedPanel.minY + chrome.minY,
                width: croppedPanel.width,
                height: croppedPanel.height
            )
        } else {
            contentPanel = croppedPanel
        }
        await contentPanelCache.set(contentPanel, forChrome: chrome)
        usedVLM = true
        NSLog("findTitleAndBodyAnchors: VLM content panel %.0fx%.0f at (%.0f,%.0f) [cropped Chrome %.0fx%.0f]",
              contentPanel.width, contentPanel.height, contentPanel.minX, contentPanel.minY,
              chrome.width, chrome.height)
    }

    // Extend the content panel UPWARD by ~80pt so Vision OCR can see the
    // article H1 heading, which VLM typically classifies into the "header"
    // region above the content column. Without this extension, the title
    // detector never sees the H1 as an OCR line.
    let ocrPanel = CGRect(
        x: contentPanel.minX,
        y: max(chrome.minY + 100, contentPanel.minY - 80),
        width: contentPanel.width,
        height: contentPanel.height + (contentPanel.minY - max(chrome.minY + 100, contentPanel.minY - 80))
    )
    // Per-frame Vision OCR inside the extended cached panel — fast, stable.
    guard let panel = await OCRScanner.scanPanel(
        image: screen, panelBounds: ocrPanel, label: "CONTENT"
    ), !panel.lines.isEmpty else {
        NSLog("findTitleAndBodyAnchors: OCR returned no lines; invalidating panel cache")
        await contentPanelCache.invalidate()
        return nil
    }

    // Title detection. A real H1 has a distinct signature on any article-
    // style page: SHORT text (usually < 60 chars, often a few words), near
    // the top of the content column, AND significantly taller than body
    // text (>= 1.8x the 25th-percentile body height). Body paragraphs are
    // LONG (wrapping across many words) and shouldn't be confused for
    // titles.
    let sortedHeights = panel.lines.map { $0.bounds.height }.sorted()
    let q25Index = max(0, sortedHeights.count / 4)
    let q25Height = sortedHeights[q25Index]
    let sortedByY = panel.lines.sorted { $0.bounds.minY < $1.bounds.minY }
    // Log the first few OCR lines for diagnosis.
    for (idx, ln) in sortedByY.prefix(6).enumerated() {
        NSLog("  OCRline[%d] h=%.0f w=%.0f chars=%d text='%@'",
              idx, ln.bounds.height, ln.bounds.width,
              ln.text.count, String(ln.text.prefix(60)))
    }
    // Title candidate: top-most line that looks like a heading.
    //   - length cap 140 chars per-line (each line of a wrapped title stays
    //     well within this even for very long article titles)
    //   - height >= 1.8x the 25th-percentile body height (distinctive;
    //     reliably separates real headings from body paragraphs)
    //   - minimum width 80pt (not a tiny badge)
    // NO upper width bound — a real H1 can legitimately wrap to the full
    // column width; the height threshold is what distinguishes title from
    // body on any article-style page.
    let titleCandidate = sortedByY.first { line in
        line.text.count <= 140 &&
        line.bounds.height >= q25Height * 1.8 &&
        line.bounds.width >= 80
    }
    guard let titleLine = titleCandidate else {
        NSLog("findTitleAndBodyAnchors: no title candidate in visible OCR; title anchor nil")
        // Still return a body anchor (full content panel) so the navy card
        // can remain even when the H1 has scrolled out of view.
        let cycleMs = (CFAbsoluteTimeGetCurrent() - cycleStart) * 1000
        NSLog("findTitleAndBodyAnchors: cycle=%.0fms VLM=%@ title=NIL body only",
              cycleMs, usedVLM ? "Y" : "N")
        return (.zero, contentPanel)
    }
    let titleRect = titleLine.bounds.insetBy(dx: -8, dy: -6)

    // Body X-cluster. OCR lines can leak outside the VLM panel occasionally.
    // Tighten body rect to the X-range where most (>=60%) body lines sit.
    let bodyLines = panel.lines.filter { $0.bounds.minY > titleRect.maxY }
    let bodyXs = bodyLines.map { $0.bounds.minX }.sorted()
    let bodyEnds = bodyLines.map { $0.bounds.maxX }.sorted()
    let tightLeft: CGFloat
    let tightRight: CGFloat
    if bodyXs.count >= 3, bodyEnds.count >= 3 {
        tightLeft = bodyXs[bodyXs.count / 4]
        tightRight = bodyEnds[3 * bodyEnds.count / 4]
    } else {
        tightLeft = contentPanel.minX
        tightRight = contentPanel.maxX
    }
    let bodyTop = titleRect.maxY + 12
    let bodyRect = CGRect(
        x: tightLeft - 6,
        y: bodyTop,
        width: max(280, tightRight - tightLeft + 12),
        height: max(200, contentPanel.maxY - bodyTop)
    )

    let cycleMs = (CFAbsoluteTimeGetCurrent() - cycleStart) * 1000
    NSLog("findTitleAndBodyAnchors: cycle=%.0fms VLM=%@ title='%@' titleH=%.0f q25H=%.0f bodyW=%.0f",
          cycleMs, usedVLM ? "Y" : "N", titleLine.text, titleRect.height, q25Height, bodyRect.width)
    return (titleRect, bodyRect)
}

/// Query Chrome's active tab for the current absolute scroll position in
/// pixels. Used to drive progressive bullet reveal in the demo: bullets
/// unlock as the user scrolls past their corresponding content. Returns
/// scrollTop in pixels, or nil if query fails. DOM query is acceptable
/// here because this drives DEMO-SIDE state (what to show), not the
/// grounding anchors — those still come from the screen-view VLM+OCR
/// pipeline.
func chromeScrollPixels() -> Double? {
    let js = "(function(){var s=document.scrollingElement||document.documentElement;return s.scrollTop.toFixed(0);})()"
    let escaped = js.replacingOccurrences(of: "\"", with: "\\\"")
    let apple = "tell application \"Google Chrome\" to return execute front window's active tab javascript \"\(escaped)\""
    let t = Process()
    t.launchPath = "/usr/bin/osascript"
    t.arguments = ["-e", apple]
    let pipe = Pipe(); t.standardOutput = pipe; t.standardError = Pipe()
    do { try t.run() } catch { return nil }
    t.waitUntilExit()
    let s = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
        .trimmingCharacters(in: .whitespacesAndNewlines)
    return s.flatMap { Double($0) }
}

/// TEST ORACLE ONLY. Queries Chrome\'s DOM for exact H1 and body bounds.
/// Useful to validate that `findTitleAndBodyAnchors` (the VLM+OCR screen-view
/// grounding) returns matching rects when ground truth is available via a
/// scriptable browser. Not used in the production demo path.
func queryWikipediaAnchors(chromeBounds: CGRect) -> (CGRect, CGRect) {
    let js = """
    (function(){
      var h = document.querySelector('h1#firstHeading') || document.querySelector('h1');
      var c = document.querySelector('#mw-content-text') || document.querySelector('main') || document.body;
      if (!h || !c) return '';
      var hb = h.getBoundingClientRect();
      var cb = c.getBoundingClientRect();
      var vw = window.innerWidth, vh = window.innerHeight;
      return Math.round(hb.left)+','+Math.round(hb.top)+','+Math.round(hb.width)+','+Math.round(hb.height)
           +'|'+Math.round(cb.left)+','+Math.round(cb.top)+','+Math.round(cb.width)+','+Math.round(cb.height)
           +'|'+vw+','+vh;
    })()
    """
    let escapedJS = js.replacingOccurrences(of: "\"", with: "\\\"")
    let apple = "tell application \"Google Chrome\" to return execute front window's active tab javascript \"\(escapedJS)\""
    let task = Process()
    task.launchPath = "/usr/bin/osascript"
    task.arguments = ["-e", apple]
    let pipe = Pipe()
    task.standardOutput = pipe
    task.standardError = Pipe()
    do { try task.run() } catch {
        return fallbackAnchors(chromeBounds: chromeBounds)
    }
    task.waitUntilExit()
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    guard let result = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
          !result.isEmpty else {
        return fallbackAnchors(chromeBounds: chromeBounds)
    }
    let parts = result.split(separator: "|").map { String($0) }
    guard parts.count >= 3 else { return fallbackAnchors(chromeBounds: chromeBounds) }
    func parseRect(_ s: String) -> CGRect? {
        let nums = s.split(separator: ",").compactMap { Double($0) }
        guard nums.count == 4 else { return nil }
        return CGRect(x: nums[0], y: nums[1], width: nums[2], height: nums[3])
    }
    guard let headerViewport = parseRect(parts[0]),
          let bodyViewport = parseRect(parts[1]) else {
        return fallbackAnchors(chromeBounds: chromeBounds)
    }
    let vdims = parts[2].split(separator: ",").compactMap { Double($0) }
    let viewportHeight = vdims.count >= 2 ? vdims[1] : Double(chromeBounds.height - 121)
    let topInset = chromeBounds.height - CGFloat(viewportHeight)
    let oX = chromeBounds.minX, oY = chromeBounds.minY + topInset
    let header = CGRect(x: oX + headerViewport.minX, y: oY + headerViewport.minY,
                        width: headerViewport.width, height: headerViewport.height)
    let bh = min(bodyViewport.height, CGFloat(viewportHeight) - bodyViewport.minY - 8)
    let body = CGRect(x: oX + bodyViewport.minX, y: oY + bodyViewport.minY,
                      width: bodyViewport.width, height: max(200, bh))
    return (header, body)
}

private func fallbackAnchors(chromeBounds: CGRect) -> (CGRect, CGRect) {
    let b = chromeBounds
    return (CGRect(x: b.minX + 280, y: b.minY + 200, width: 700, height: 50),
            CGRect(x: b.minX + 280, y: b.minY + 300, width: 820, height: 420))
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
let menuBar = MenuBarController()
let dashboard = DashboardPopover(model: EngineModel.shared)
menuBar.bind(popover: dashboard)
overlay.onStatusChanged = { [weak menuBar] text in
    menuBar?.update(status: text)
    DispatchQueue.main.async { EngineModel.shared.statusLine = text }
}
overlay.setStatus("⏳ Starting...")

guard let image = captureScreen() else { exit(1) }

if #available(macOS 26.0, *) {
    let detector = NativePanelDetector()
    let state = ContentState()

    // Detect platform and inject config into all components
    let platform = PlatformConfig.detect()
    NSLog("GroundingKit: Platform = %@ (editorDark=%@)", platform.name, platform.editorThemeIsDark ? "yes" : "no")
    ChromeCapture.windowKeywords = platform.browserWindowKeywords
    OCRScanner.sidebarLabels = platform.sidebarLabels
    OCRScanner.editorThemeIsDark = platform.editorThemeIsDark
    GhostLayout.uiKeywords = platform.uiKeywords
    GeminiClient.shared.promptIOHint = platform.promptIOHint
    state.templateClassPatterns = platform.templateClassPatterns
    // When PlatformConfig explicitly selects reader mode, seed forceReading early
    // so the MCQ/coding classifier doesn't fire on the first full-screen OCR pass
    // before the VLM returns.
    if platform.overlayMode.layoutMode == .reader {
        state.forceReading = true
    }
    overlay.setStatus("Platform: \(platform.name)")
    DispatchQueue.main.async { EngineModel.shared.platformName = platform.name }

    // Load VLM in background — doesn't block
    Task.detached {
        await MainActor.run {
            overlay.setStatus("Loading VLM model...")
            EngineModel.shared.vlmState = .loading
        }
        do {
            try await detector.loadModel()
            await MainActor.run {
                overlay.setStatus("✅ VLM loaded — detecting...")
                EngineModel.shared.vlmState = .ready
            }
        } catch {
            NSLog("NativeVLM: LOAD ERROR: %@", "\(error)")
            await MainActor.run {
                overlay.setStatus("❌ VLM: \(error.localizedDescription)")
                EngineModel.shared.vlmState = .error(error.localizedDescription)
            }
        }
    }

    // GK_TWO_SPOT_DEMO — experiment: show two framing-projector cards on the
    // same page, lighting different regions. Uses Chrome window geometry for
    // deterministic rects. Re-injects every 3s so the normal reader-mode
    // Claude path can't overwrite our two-spot state.
    let isTwoSpotDemo = ProcessInfo.processInfo.environment["GK_TWO_SPOT_DEMO"] == "1"
    if isTwoSpotDemo {
        // Full bullet list for the "Whole article" card. Each entry has an
        // unlock threshold: the fraction of total article height the user
        // must have scrolled past for that bullet to appear on the card.
        // This models "summary appears AFTER its content has been exposed."
        struct ProgressiveBullet { let text: String; let unlockPx: Double }
        let bodyBullets: [ProgressiveBullet] = [
            .init(text: "Apple Silicon: SoC family across Mac, iPhone, iPad", unlockPx: 0),
            .init(text: "M-series (Mac) and A-series (mobile) share one design ethos", unlockPx: 400),
            .init(text: "Unified memory: CPU / GPU / Neural Engine share RAM", unlockPx: 1200),
            .init(text: "Replaced Intel x86 in Mac starting 2020 (M1 transition)", unlockPx: 2400),
            .init(text: "ARM-based, designed in-house, fabricated by TSMC", unlockPx: 4000),
        ]

        NSLog("GK_TWO_SPOT_DEMO: env var detected; scheduling demo task")
        Task.detached {
            NSLog("GK_TWO_SPOT_DEMO: task started — sleeping 12s for VLM load + first panel detect")
            try? await Task.sleep(nanoseconds: 12_000_000_000)
            NSLog("GK_TWO_SPOT_DEMO: entering main loop")
            while true {
                let screenImage: CGImage? = autoreleasepool {
                    captureScreenExcluding(windowID: CGWindowID(overlay.windowNumber))
                }
                if let screenImage = screenImage,
                   let anchors = await findTitleAndBodyAnchors(screen: screenImage, detector: detector) {
                    let titleRect = anchors.title
                    let bodyRect = anchors.body
                    // Scroll percentage drives progressive bullet reveal.
                    // Defaults to 0 (only the first bullet) if DOM query fails —
                    // safe fallback; the VLM+OCR path is unchanged either way.
                    let scrollPx = chromeScrollPixels() ?? 0.0
                    let unlocked = bodyBullets.filter { $0.unlockPx <= scrollPx }.map { $0.text }
                    NSLog("GK_TWO_SPOT_DEMO: scroll=%.0fpx bullets unlocked=%d/%d",
                          scrollPx, unlocked.count, bodyBullets.count)

                    await MainActor.run {
                        var spots: [SpotlightItem] = []
                        // Body card — always shown while content is visible.
                        // Bullets accumulate as user scrolls.
                        spots.append(SpotlightItem(
                            anchor: bodyRect,
                            bullets: unlocked.isEmpty ? ["…reading the article…"] : unlocked,
                            hueIndex: 0,
                            title: "Whole article"
                        ))
                        // Title card — only shown while the H1 heading is
                        // actually visible in the viewport. findTitle… returns
                        // a zero rect when no OCR line satisfies the title
                        // heuristic (H1 scrolled out of view).
                        if titleRect != .zero &&
                           titleRect.minY > 0 &&
                           titleRect.maxY < CGFloat(screenImage.height) {
                            spots.append(SpotlightItem(
                                anchor: titleRect,
                                bullets: [
                                    "Article heading currently visible on screen",
                                    "Scope: what the article is about",
                                ],
                                hueIndex: 1,
                                title: "Title / scope"
                            ))
                        }
                        overlay.setSpotlights(spots)
                    }
                } else {
                    NSLog("GK_TWO_SPOT_DEMO: grounding failed this cycle, retrying")
                }
                try? await Task.sleep(nanoseconds: 2_000_000_000)
            }
        }
    }

    // Initial deep scan for content only — no panel boxes (VLM handles those)
    Task {
        let scan = await OCRScanner.scanFull(image: image)
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

    // Deterministic reader mode — env override for reliable demos.
    // When set, skip VLM panel detection entirely and use the Chrome window as the
    // content panel. The VLM still loads (for visual "panels detected" status) but
    // its output is not used for bounds. Intended for recording demo GIFs against
    // single-panel sites like Wikipedia/arXiv where VLM output varies between runs.
    let forceReaderMode = ProcessInfo.processInfo.environment["GK_FORCE_READER"] == "1"

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
        // Dashboard Start/Stop toggle — when stopped, skip all scan work.
        guard EngineModel.shared.isRunning else {
            overlay.setStatus("⏸ Paused")
            return
        }
        guard !scanInProgress else { return }
        scanInProgress = true
        cycleCount += 1
        let cycleInRound = ((cycleCount - 1) % 7) + 1  // 1-7
        if cycleInRound == 1 { roundCount += 1 }
        let rndPublish = roundCount
        let cycPublish = cycleInRound
        DispatchQueue.main.async {
            EngineModel.shared.round = rndPublish
            EngineModel.shared.cycleInRound = cycPublish
        }

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

            // Reader-mode deterministic override — bypasses VLM stochasticity.
            // Uses Chrome window bounds as the content panel. Intended for demos
            // against single-panel sites (Wikipedia, arXiv).
            if forceReaderMode && cycleInRound == 1 && !vlmSucceeded {
                let chromeDetected = ChromeCapture.chromeBounds()
                let chrome = chromeDetected != .zero ? chromeDetected : CGRect(x: 100, y: 100, width: 1200, height: 800)
                // Leave room for Chrome's top chrome (tabs + URL bar: ~110pt) and the bookmarks bar.
                let contentInset: CGFloat = 130
                let contentPanel = CGRect(
                    x: chrome.minX + 10,
                    y: chrome.minY + contentInset,
                    width: chrome.width - 20,
                    height: chrome.height - contentInset - 20
                )
                state.questionBounds = contentPanel
                state.editorBounds = .zero
                state.forceReading = true
                vlmSucceeded = true
                pixelDiff.reset()
                state.questionScrollSignal.reset()
                await MainActor.run {
                    overlay.clear()
                    // Anchor the soft halo at the content panel — no hard blue frame.
                    // Skip when two-spot demo is driving; it injects its own spotlights.
                    if !isTwoSpotDemo {
                        overlay.showReaderSummary("", nearPanel: contentPanel)
                    }
                    setStatusSegments(round: roundCount, isVLM: false, detail: "reader mode · Chrome bounds locked")
                    EngineModel.shared.vlmState = .ready
                    EngineModel.shared.questionBounds = contentPanel
                    EngineModel.shared.editorBounds = .zero
                }
                NSLog("ReaderMode: forced via GK_FORCE_READER — content panel %.0fx%.0f at (%.0f, %.0f)",
                      contentPanel.width, contentPanel.height, contentPanel.minX, contentPanel.minY)
                return
            }

            // VLM scan frequency adapts to round number:
            //   Round 1: cycles 1, 3, 5 (3/7) — fast panel lock-in after startup
            //   Round 2: cycles 1, 4     (2/7) — refinement
            //   Round 3+: cycle 1 only   (1/7) — steady state
            let shouldRunVLM: Bool
            if forceReaderMode {
                shouldRunVLM = false  // deterministic mode — never re-run VLM
            } else if roundCount == 1 {
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
                await MainActor.run {
                    setStatusSegments(round: rnd, isVLM: true, detail: "processing...")
                    EngineModel.shared.vlmState = .inferring
                }

                // Choose VLM prompt mode from platform config (reader vs two-panel).
                // .auto starts with two-panel; main.swift auto-switches to reader based on
                // editor-width heuristic after first detection.
                let vlmMode: NativePanelDetector.DetectionMode
                switch platform.overlayMode.layoutMode {
                case .reader:   vlmMode = .reader
                case .twoPanel: vlmMode = .twoPanel
                case .auto:     vlmMode = state.forceReading ? .reader : .twoPanel
                }

                Task.detached {
                    if let analysis = await detector.detectPanels(from: vlmImage, mode: vlmMode) {
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
                        // Question panel: 20-95% of screen width.
                        //  - LeetCode / HackerRank style (2-panel): ~50% width
                        //  - MCQ questions: 60%+ (no code editor)
                        //  - Single-panel layouts (Wikipedia articles, docs, PRs): up to ~95%
                        let screenW = NSScreen.main?.frame.width ?? 1800
                        let qWidthRatio = newQ.width / screenW
                        if qWidthRatio < 0.20 || qWidthRatio > 0.95 {
                            NSLog("NativeVLM: REJECTED — Q width ratio %.0f%% out of range (20-95%%)", qWidthRatio * 100)
                            vlmRunning = false
                            return
                        }

                        // Detect reader mode — single-panel layout where the "editor" panel
                        // either collapsed to 0x0 after Chrome clamp or is a thin sidebar
                        // (< 15% of screen width). Activates unless Platform overrides to .twoPanel.
                        let editorWidthRatio = screenW > 0 ? newE.width / screenW : 0
                        let detectedReader = editorWidthRatio < 0.15
                        let isReader: Bool
                        switch platform.overlayMode.layoutMode {
                        case .reader:   isReader = true
                        case .twoPanel: isReader = false
                        case .auto:     isReader = detectedReader
                        }
                        if state.forceReading != isReader {
                            state.forceReading = isReader
                            NSLog("LayoutMode: %@ (editor %.0f%% of screen, platform=%@)",
                                  isReader ? "reader" : "two-panel",
                                  editorWidthRatio * 100,
                                  platform.overlayMode.layoutMode.rawValue)
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
                            // Reader mode uses a soft halo behind the content + the floating
                            // summary card; skip the hard blue/green rectangular borders that
                            // belong to two-panel test-taking layouts.
                            if !state.forceReading {
                                overlay.showPanel(PanelRect(x: state.questionBounds.minX, y: state.questionBounds.minY,
                                                            width: state.questionBounds.width, height: state.questionBounds.height,
                                                            label: "QUESTION", paragraphCount: 0), color: "blue", label: "QUESTION")
                                overlay.showPanel(PanelRect(x: state.editorBounds.minX, y: state.editorBounds.minY,
                                                            width: state.editorBounds.width, height: state.editorBounds.height,
                                                            label: "EDITOR", paragraphCount: 0), color: "green", label: "EDITOR")
                            } else if !isTwoSpotDemo {
                                // Pre-register the anchor so the soft halo draws immediately,
                                // even before the summary text arrives.
                                overlay.showReaderSummary("", nearPanel: state.questionBounds)
                            }
                            setStatusSegments(round: rnd, isVLM: true, detail: "done ✓")
                            EngineModel.shared.vlmState = .ready
                            EngineModel.shared.questionBounds = state.questionBounds
                            EngineModel.shared.editorBounds = state.editorBounds
                        }
                    } else {
                        await MainActor.run {
                            setStatusSegments(round: rnd, isVLM: true, detail: "failed ✗")
                            EngineModel.shared.vlmState = .ready
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
                    overlay.clearReaderSummary()
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
                scan = await OCRScanner.scanWithBounds(
                    image: capturedImg,
                    questionBounds: state.questionBounds,
                    editorBounds: state.editorBounds)
            } else {
                scan = await OCRScanner.scanFull(image: capturedImg)
            }

            // Update FULL state from scan (question text + editor lines + solution matching)
            state.update(from: scan)

            // Publish OCR + solver state into dashboard model
            let qText = state.questionText
            let accChars = qText.count
            let accLines = qText.isEmpty ? 0 : qText.split(separator: "\n").count
            let eLines = state.editorLines.count
            let scrollDown = state.questionScrollSignal.needsScrollDown
            let solverReady = state.solution
            let claudePending = state.claudeInFlight
            await MainActor.run {
                EngineModel.shared.accumulatedLines = accLines
                EngineModel.shared.accumulatedChars = accChars
                EngineModel.shared.questionText = qText
                EngineModel.shared.editorLineCount = eLines
                EngineModel.shared.scrollDownNeeded = scrollDown
                if let sol = solverReady {
                    EngineModel.shared.solverState = .ready(lineCount: sol.lines.count, source: sol.problemId)
                    EngineModel.shared.solutionCode = sol.lines.map(\.text).joined(separator: "\n")
                } else if claudePending {
                    EngineModel.shared.solverState = .waiting
                } else {
                    EngineModel.shared.solverState = .idle
                }
            }

            // Auto-scroll: if the panel still has content below the fold and we haven't
            // already fired the downstream action (coding solution or reader summary),
            // inject a CGEvent scroll to reveal the next viewport for the accumulator.
            let needsDownstreamOutput = state.questionType == .reading
                ? state.readingSummary.isEmpty
                : state.solution == nil
            if state.questionScrollSignal.needsScrollDown && needsDownstreamOutput {
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

            // Route Reading vs MCQ vs Coding
            let isReading = state.questionType == .reading
            let isMCQ = state.questionType == .mcq
            let mode = platform.overlayMode

            // Generate editor-side clues only if stepAdvancement is enabled (never in reader mode)
            let newClues: [GhostClue]
            if isReading {
                newClues = []
            } else if isMCQ {
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

                if isReading {
                    // Reader mode: three stages
                    //   Stage 1 (collecting): red boxes around detected text, scroll pulse
                    //   Stage 2 (summarizing): blue border while Claude works
                    //   Stage 3 (summary): floating summary card anchored next to the panel
                    let summary = state.readingSummary
                    let charCount = state.questionText.count
                    NSLog("Reader route: summaryLen=%d charCount=%d questionBounds=%.0fx%.0f",
                          summary.count, charCount, state.questionBounds.width, state.questionBounds.height)
                    if !summary.isEmpty && state.questionBounds != .zero {
                        // Stage 3 — floating summary card (elegant, non-intrusive)
                        overlay.showCollectingBoxes([])
                        overlay.setQuestionPanelBlinking(false)
                        // The solution-on-panel overlay is cleared so only the floating card is visible
                        overlay.showSolutionOnQuestion(code: "", questionBounds: .zero)
                        if !diagnosticHideOverlay && !isTwoSpotDemo {
                            overlay.showReaderSummary(summary, nearPanel: state.questionBounds)
                        }
                        let bulletCount = summary.components(separatedBy: "\n").filter { $0.contains("•") }.count
                        setStatusSegments(round: rnd, isVLM: false, detail: "\(scanNum)/6 · Summary (\(bulletCount) bullets)")
                    } else if state.readingRequested {
                        // Stage 2 — Claude in flight
                        overlay.showSolutionOnQuestion(code: "", questionBounds: .zero)
                        if vlmSucceeded, let qPanel = scan.questionPanel {
                            let qb = state.questionBounds
                            let boxes = qPanel.lines
                                .filter { $0.bounds.midX >= qb.minX && $0.bounds.midX <= qb.maxX }
                                .filter { $0.bounds.midY >= qb.minY && $0.bounds.midY <= qb.maxY }
                                .map { $0.bounds }
                            overlay.showCollectingBoxes(boxes)
                        }
                        overlay.setQuestionPanelBlinking(true)
                        setStatusSegments(round: rnd, isVLM: false, detail: "\(scanNum)/6 · Summarizing \(charCount) chars…")
                    } else {
                        // Stage 1 — accumulating content
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
                        let scrollArrow = state.questionScrollSignal.needsScrollDown ? " ▼" : ""
                        setStatusSegments(round: rnd, isVLM: false, detail: "\(scanNum)/6 · Reading \(charCount) chars\(scrollArrow)")
                    }
                } else if isMCQ {
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
