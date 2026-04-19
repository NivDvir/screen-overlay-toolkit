import Vision
import CoreGraphics
import AppKit

/// Deep scan using RecognizeDocumentsRequest (WWDC25, macOS 26+).
/// Two modes:
/// 1. scanPanel() — scans ONLY within a known panel's bounds (from LLM analysis)
/// 2. scanFull() — full-screen scan with Y-band + X-cluster (fallback)

// MARK: - Result Types

struct ScanResult {
    let timestamp: CFAbsoluteTime
    let durationMs: Double
    let questionPanel: PanelState?
    let editorPanel: PanelState?
    let allLines: [DetectedLine]
}

struct PanelState {
    let bounds: CGRect
    let label: String
    let lines: [DetectedLine]
    let lineHeight: CGFloat
}

struct DetectedLine {
    let text: String       // OCR'd text (line numbers stripped)
    let rawText: String    // Original OCR text (before cleanup)
    let bounds: CGRect
    let confidence: Float

    init(text: String, bounds: CGRect, confidence: Float = 1.0, stripLineNumbers: Bool = false) {
        self.rawText = text
        // Strip leading line numbers ONLY for editor panel lines.
        // Line numbers are short (1-4 digits) followed by spaces.
        // Content numbers like "150000 can be fitted in:" must NOT be stripped.
        if stripLineNumbers, let range = text.range(of: #"^\s*\d{1,4}\s{2,}"#, options: .regularExpression) {
            // Only strip if the number is short (≤4 digits) and followed by 2+ spaces
            // (code editors use "  7  " padding, content uses "150000 can be...")
            self.text = String(text[range.upperBound...])
        } else {
            self.text = text
        }
        self.bounds = bounds
        self.confidence = confidence
    }
}

// MARK: - Deep Scanner

@available(macOS 26.0, *)
struct DeepScanner {

    /// Platform-specific sidebar labels to filter from question panel OCR — set at startup
    static var sidebarLabels: [String] = ["editorial", "discussions", "submissions", "leaderboard", "problem"]

    /// Whether the editor uses a dark theme (controls image inversion for OCR) — set at startup
    static var editorThemeIsDark: Bool = true

    /// Scan a single panel by cropping the image to its known bounds.
    /// Returns lines found within that panel, with coordinates in full-screen space.
    static func scanPanel(image: CGImage, panelBounds: CGRect, label: String) async -> PanelState? {
        // Wrap in autoreleasepool to release intermediate CGImage/CGContext allocations.
        // Without this, 3000+ invocations over 100 min would leak ~900MB.
        return autoreleasepool {
        let start = CFAbsoluteTimeGetCurrent()
        let scale = screenScaleFactor

        // Crop image to panel bounds (pixel coordinates)
        let pixelRect = CGRect(
            x: panelBounds.minX * scale,
            y: panelBounds.minY * scale,
            width: panelBounds.width * scale,
            height: panelBounds.height * scale
        ).integral

        let imgRect = CGRect(x: 0, y: 0, width: image.width, height: image.height)
        let safeCrop = pixelRect.intersection(imgRect)
        guard !safeCrop.isEmpty, safeCrop.width > 100, safeCrop.height > 100 else {
            NSLog("DeepScan[%@]: crop too small", label)
            return nil
        }

        guard let cropped = image.cropping(to: safeCrop) else {
            NSLog("DeepScan[%@]: crop failed", label)
            return nil
        }

        // Debug: save crop for inspection (autoreleasepool prevents NSBitmapImageRep leak)
        if label == "QUESTION" {
            autoreleasepool {
                let bm = NSBitmapImageRep(cgImage: cropped)
                if let png = bm.representation(using: .png, properties: [:]) {
                    try? png.write(to: URL(fileURLWithPath: "/tmp/ccsv_question_crop.png"))
                }
            }
        }

        // Preprocessing for OCR accuracy:
        // - EDITOR (dark theme): invert colors so syntax-highlighted text becomes readable
        // - QUESTION: grayscale + contrast boost so colored code keywords become uniform dark text
        let ocrImage: CGImage
        if label == "EDITOR" && editorThemeIsDark, let inverted = invertImage(cropped) {
            ocrImage = inverted
        } else if label == "QUESTION", let enhanced = grayscaleHighContrast(cropped) {
            // Save enhanced image for debugging
            autoreleasepool {
                let bm = NSBitmapImageRep(cgImage: enhanced)
                if let png = bm.representation(using: .png, properties: [:]) {
                    try? png.write(to: URL(fileURLWithPath: "/tmp/ccsv_question_enhanced.png"))
                }
            }
            ocrImage = enhanced
        } else {
            ocrImage = cropped
        }

        let cropSize = CGSize(width: ocrImage.width, height: ocrImage.height)

        // OCR: VNRecognizeTextRequest for ALL panels.
        // RecognizeDocumentsRequest drops indented/colored code lines on light themes.
        // VNRecognizeTextRequest finds ALL text regardless of layout or color.
        let vnRequest = VNRecognizeTextRequest()
        vnRequest.recognitionLevel = .accurate
        vnRequest.usesLanguageCorrection = false  // Don't auto-correct code identifiers
        let vnHandler = VNImageRequestHandler(cgImage: ocrImage)
        do {
            try vnHandler.perform([vnRequest])
        } catch {
            NSLog("DeepScan[%@]: VNText failed: %@", label, error.localizedDescription)
            return nil
        }
        guard let results = vnRequest.results, !results.isEmpty else {
            NSLog("DeepScan[%@]: VNText no results", label)
            return nil
        }
        let lines: [DetectedLine] = results.compactMap { obs in
            guard let candidate = obs.topCandidates(1).first else { return nil }
            let text = candidate.string
            guard !text.isEmpty else { return nil }
            let conf = candidate.confidence
            guard conf > 0.3 else { return nil }
            // VN bounding box: normalized (0-1), bottom-left origin → crop pixel coords
            let bb = obs.boundingBox
            let cropRect = CGRect(
                x: bb.origin.x * CGFloat(ocrImage.width),
                y: (1 - bb.origin.y - bb.height) * CGFloat(ocrImage.height),
                width: bb.width * CGFloat(ocrImage.width),
                height: bb.height * CGFloat(ocrImage.height)
            )
            let logical = CGRect(
                x: cropRect.origin.x / scale + panelBounds.minX,
                y: cropRect.origin.y / scale + panelBounds.minY,
                width: cropRect.size.width / scale,
                height: cropRect.size.height / scale
            )
            guard logical.width > 3 && logical.height > 5 else { return nil }
            // Filter editor gutter artifacts: line numbers, fold triangles, +/- indicators
            if label == "EDITOR" {
                let trimmed = text.trimmingCharacters(in: .whitespaces)
                let isLeftGutter = logical.minX < panelBounds.minX + 60

                // Pure line numbers: "6", "10", "123"
                let isDigitsOnly = !trimmed.isEmpty && trimmed.allSatisfy({ $0.isNumber })
                // Line numbers with fold dash: "4-", "12-"
                let isDigitDash = trimmed.count <= 4 && trimmed.hasSuffix("-") &&
                    trimmed.dropLast().allSatisfy({ $0.isNumber })
                // Fold/gutter symbols: "+", "-", ">", "›", "<", "«", single punctuation
                let isGutterSymbol = trimmed.count <= 3 && !trimmed.isEmpty &&
                    trimmed.allSatisfy({ !$0.isLetter || !"abcdefghijklmnopqrstuvwxyz".contains($0.lowercased()) })
                // Very short fragments from gutter area: '">".' etc.
                let isShortGutterNoise = trimmed.count <= 4 && isLeftGutter

                if isLeftGutter && (isDigitsOnly || isDigitDash || isGutterSymbol) { return nil }
                if isShortGutterNoise && !trimmed.contains(" ") { return nil }
            }
            // Filter sidebar labels (site-specific — configure via PlatformConfig.sidebarLabels)
            let lower = text.lowercased().trimmingCharacters(in: .whitespaces)
            if Self.sidebarLabels.contains(where: { lower.hasPrefix($0) || $0.hasPrefix(lower) }) { return nil }
            // Filter sidebar question numbers: "1", "2-", "3", "+.", "Co" etc.
            // These are navigation buttons on the far left of the question panel.
            // They appear as narrow OCR detections (width < 40px) at the left edge.
            if label == "QUESTION" {
                let trimmed = text.trimmingCharacters(in: .whitespaces)
                let isLeftSidebar = logical.minX < panelBounds.minX + 55
                let isNarrow = logical.width < 40
                // Pure digits or digit-dash: "1", "2-", "10"
                let isDigitsOrDash = !trimmed.isEmpty && trimmed.allSatisfy({ $0.isNumber || $0 == "-" })
                // Single punctuation or very short noise: "+.", "Co", ","
                let isTinyNoise = trimmed.count <= 2 && !trimmed.allSatisfy({ $0.isLetter })
                if isLeftSidebar && isNarrow && (isDigitsOrDash || isTinyNoise) { return nil }
            }
            // Y-filtering: skip title bar and bottom margin
            // Editor needs larger top margin to skip tab bar
            let topMargin: CGFloat = label == "EDITOR" ? 45 : 25
            let contentTop = panelBounds.minY + topMargin
            let contentBottom = panelBounds.maxY - 10
            guard logical.midY >= contentTop && logical.midY <= contentBottom else { return nil }
            return DetectedLine(text: text, bounds: logical, confidence: conf,
                               stripLineNumbers: label == "EDITOR")
        }

        let sortedLines = lines.sorted { $0.bounds.midY < $1.bounds.midY }
        let lineHeight = computeLineHeight(from: sortedLines)

        // Debug: dump raw transcripts for QUESTION panel to file
        if label == "QUESTION" {
            let dump = sortedLines.enumerated().map { (i, l) in
                "[\(i)] raw='\(l.rawText)' text='\(l.text)' y=\(Int(l.bounds.midY))"
            }.joined(separator: "\n")
            try? dump.write(toFile: "/tmp/ccsv_ocr_dump.txt", atomically: true, encoding: .utf8)
        }

        let ms = (CFAbsoluteTimeGetCurrent() - start) * 1000
        NSLog("DeepScan[%@]: %d lines in %.0fms (lineHeight=%.1f)",
              label, sortedLines.count, ms, lineHeight)

        return PanelState(
            bounds: panelBounds,
            label: label,
            lines: sortedLines,
            lineHeight: lineHeight
        )
        }  // autoreleasepool
    }

    /// Scan both panels using LLM-provided bounds.
    /// Each panel is scanned independently within its own domain.
    static func scanWithBounds(image: CGImage, questionBounds: CGRect, editorBounds: CGRect) async -> ScanResult {
        let start = CFAbsoluteTimeGetCurrent()

        // Scan both panels in parallel
        async let qScan = scanPanel(image: image, panelBounds: questionBounds, label: "QUESTION")
        async let eScan = scanPanel(image: image, panelBounds: editorBounds, label: "EDITOR")

        let questionPanel = await qScan
        let editorPanel = await eScan

        let allLines = (questionPanel?.lines ?? []) + (editorPanel?.lines ?? [])
        let ms = (CFAbsoluteTimeGetCurrent() - start) * 1000

        NSLog("DeepScan: bounded scan %.0fms — Q:%d lines, E:%d lines",
              ms, questionPanel?.lines.count ?? 0, editorPanel?.lines.count ?? 0)

        return ScanResult(
            timestamp: start,
            durationMs: ms,
            questionPanel: questionPanel,
            editorPanel: editorPanel,
            allLines: allLines
        )
    }

    /// Full-screen scan (fallback when no LLM bounds available)
    static func scanFull(image: CGImage) async -> ScanResult {
        let start = CFAbsoluteTimeGetCurrent()
        let imgSize = CGSize(width: image.width, height: image.height)
        let scale = screenScaleFactor

        let request = RecognizeDocumentsRequest()
        let handler = ImageRequestHandler(image)

        let observations: [DocumentObservation]
        do {
            observations = try await handler.perform(request)
        } catch {
            NSLog("DeepScan: failed: %@", error.localizedDescription)
            return ScanResult(timestamp: start, durationMs: elapsed(start), questionPanel: nil, editorPanel: nil, allLines: [])
        }

        guard let doc = observations.first?.document else {
            NSLog("DeepScan: no document")
            return ScanResult(timestamp: start, durationMs: elapsed(start), questionPanel: nil, editorPanel: nil, allLines: [])
        }

        let allLines: [DetectedLine] = doc.text.lines.compactMap { line in
            let imgRect = line.boundingRegion.boundingBox.toImageCoordinates(imgSize, origin: .upperLeft)
            let logical = CGRect(
                x: imgRect.origin.x / scale,
                y: imgRect.origin.y / scale,
                width: imgRect.size.width / scale,
                height: imgRect.size.height / scale
            )
            guard logical.width > 3 && logical.height > 5 else { return nil }
            // Allow short transcripts (single digits like "5" in Sample Input)
            guard !line.transcript.isEmpty else { return nil }
            let conf = line.confidence ?? 1.0
            guard conf > 0.3 else { return nil }
            return DetectedLine(text: line.transcript, bounds: logical, confidence: conf)
        }

        // Y-band + X-cluster (existing logic)
        let contentLines = filterToContentBand(allLines)
        guard contentLines.count >= 4 else {
            return ScanResult(timestamp: start, durationMs: elapsed(start), questionPanel: nil, editorPanel: nil, allLines: allLines)
        }

        let xCenters = contentLines.map { $0.bounds.midX }.sorted()
        guard let dx = findBestXGap(xCenters: xCenters, lines: contentLines) else {
            return ScanResult(timestamp: start, durationMs: elapsed(start), questionPanel: nil, editorPanel: nil, allLines: allLines)
        }

        let leftLines = contentLines.filter { $0.bounds.midX < dx }
        let rightLines = contentLines.filter { $0.bounds.midX >= dx }

        let leftLabel = classifyLines(leftLines)
        let rightLabel = classifyLines(rightLines)
        let leftPanel = buildPanelState(lines: leftLines, label: leftLabel)
        let rightPanel = buildPanelState(lines: rightLines, label: rightLabel)

        let questionPanel = leftLabel == "QUESTION" ? leftPanel : rightPanel
        let editorPanel = leftLabel == "EDITOR" ? leftPanel : rightPanel

        let ms = elapsed(start)
        NSLog("DeepScan: full scan %.0fms — %@ (%d) | %@ (%d)",
              ms, leftLabel, leftLines.count, rightLabel, rightLines.count)

        return ScanResult(timestamp: start, durationMs: ms,
                          questionPanel: questionPanel, editorPanel: editorPanel, allLines: allLines)
    }

    // MARK: - Image Processing

    /// Convert to grayscale with contrast enhancement for OCR.
    /// Syntax-highlighted code (blue/red keywords on white) confuses Vision OCR —
    /// it randomly drops lines based on text color. Grayscale removes the color
    /// distraction; contrast boost sharpens text-vs-background edges.
    private static func grayscaleHighContrast(_ image: CGImage) -> CGImage? {
        let w = image.width, h = image.height
        guard let ctx = CGContext(
            data: nil, width: w, height: h,
            bitsPerComponent: 8, bytesPerRow: w * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }

        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))

        guard let data = ctx.data else { return nil }
        let ptr = data.bindMemory(to: UInt8.self, capacity: w * h * 4)

        for i in stride(from: 0, to: w * h * 4, by: 4) {
            let r = Float(ptr[i])
            let g = Float(ptr[i + 1])
            let b = Float(ptr[i + 2])

            // Luminance-based grayscale (ITU-R BT.601)
            let lum = 0.299 * r + 0.587 * g + 0.114 * b

            // Contrast stretch: text (dark pixels) → near-black, background → white
            let out: UInt8
            if lum < 180 {
                out = UInt8(max(0, lum * 0.55))
            } else {
                out = UInt8(min(255, 255 - (255 - lum) * 0.2))
            }

            ptr[i]     = out
            ptr[i + 1] = out
            ptr[i + 2] = out
        }

        return ctx.makeImage()
    }

    /// Invert a CGImage (dark→light). Improves OCR accuracy on dark-theme code editors
    /// where syntax-highlighted text (green imports, orange keywords) is invisible to
    /// RecognizeDocumentsRequest but white-on-dark text gets detected fine.
    private static func invertImage(_ image: CGImage) -> CGImage? {
        let w = image.width, h = image.height
        guard let ctx = CGContext(
            data: nil, width: w, height: h,
            bitsPerComponent: 8, bytesPerRow: w * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }

        // Draw original
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))

        guard let data = ctx.data else { return nil }
        let ptr = data.bindMemory(to: UInt8.self, capacity: w * h * 4)

        // Invert RGB channels (leave alpha untouched)
        for i in stride(from: 0, to: w * h * 4, by: 4) {
            ptr[i]     = 255 - ptr[i]     // R
            ptr[i + 1] = 255 - ptr[i + 1] // G
            ptr[i + 2] = 255 - ptr[i + 2] // B
        }

        return ctx.makeImage()
    }

    // MARK: - Helpers

    private static func computeLineHeight(from lines: [DetectedLine]) -> CGFloat {
        guard lines.count >= 2 else { return 21 }
        var spacings: [CGFloat] = []
        for i in 1..<lines.count {
            let s = lines[i].bounds.midY - lines[i-1].bounds.midY
            if s > 5 && s < 50 { spacings.append(s) }
        }
        return spacings.isEmpty ? 21 : spacings.sorted()[spacings.count / 2]
    }

    private static func filterToContentBand(_ lines: [DetectedLine]) -> [DetectedLine] {
        let sorted = lines.sorted { $0.bounds.midY < $1.bounds.midY }
        guard sorted.count > 5 else { return lines }

        struct YGap { let index: Int; let midY: CGFloat }
        var gaps: [YGap] = []
        for i in 1..<sorted.count {
            let gap = sorted[i].bounds.minY - sorted[i-1].bounds.maxY
            if gap > 25 {
                let mid = (sorted[i-1].bounds.maxY + sorted[i].bounds.minY) / 2
                gaps.append(YGap(index: i, midY: mid))
            }
        }
        guard !gaps.isEmpty else { return lines }

        let boundaries = [0] + gaps.map { $0.index } + [sorted.count]
        var bestScore: CGFloat = 0
        var bestMinY: CGFloat = 0
        var bestMaxY: CGFloat = 2000

        for b in 0..<(boundaries.count - 1) {
            let startIdx = boundaries[b]
            let endIdx = boundaries[b + 1]
            let count = endIdx - startIdx
            guard count >= 4 else { continue }
            let band = Array(sorted[startIdx..<endIdx])
            let xs = band.map { $0.bounds.midX }
            let xSpread = (xs.max() ?? 0) - (xs.min() ?? 0)
            let score = xSpread * CGFloat(count)
            if score > bestScore {
                bestScore = score
                bestMinY = b > 0 ? gaps[b - 1].midY : 0
                bestMaxY = b < gaps.count ? gaps[b].midY : 2000
            }
        }
        return lines.filter { $0.bounds.midY > bestMinY && $0.bounds.midY < bestMaxY }
    }

    private static func findBestXGap(xCenters: [CGFloat], lines: [DetectedLine]) -> CGFloat? {
        var bestGap: (mid: CGFloat, size: CGFloat) = (0, 0)
        let total = lines.count
        for i in 1..<xCenters.count {
            let gap = xCenters[i] - xCenters[i-1]
            if gap > 40 {
                let mid = (xCenters[i-1] + xCenters[i]) / 2
                let leftCount = lines.filter { $0.bounds.midX < mid }.count
                let rightCount = lines.filter { $0.bounds.midX >= mid }.count
                if CGFloat(leftCount) / CGFloat(total) >= 0.15 && CGFloat(rightCount) / CGFloat(total) >= 0.15 && gap > bestGap.size {
                    bestGap = (mid, gap)
                }
            }
        }
        return bestGap.size > 0 ? bestGap.mid : nil
    }

    private static func classifyLines(_ lines: [DetectedLine]) -> String {
        var codeScore = 0, textScore = 0
        for line in lines {
            let t = line.text
            if t.contains("{") || t.contains("}") { codeScore += 3 }
            if t.contains(";") { codeScore += 2 }
            if t.contains("public") || t.contains("private") || t.contains("class ") { codeScore += 3 }
            if t.contains("return ") || t.contains("import ") { codeScore += 2 }
            if t.contains("the ") || t.contains("is ") { textScore += 1 }
            if t.contains("?") || t.contains("Example") { textScore += 2 }
            if t.split(separator: " ").count > 8 { textScore += 2 }
        }
        return codeScore > textScore ? "EDITOR" : "QUESTION"
    }

    private static func buildPanelState(lines: [DetectedLine], label: String) -> PanelState {
        guard !lines.isEmpty else { return PanelState(bounds: .zero, label: label, lines: [], lineHeight: 21) }
        let minX = lines.map { $0.bounds.minX }.min()!
        let minY = lines.map { $0.bounds.minY }.min()!
        let maxX = lines.map { $0.bounds.maxX }.max()!
        let maxY = lines.map { $0.bounds.maxY }.max()!
        let sorted = lines.sorted { $0.bounds.midY < $1.bounds.midY }
        return PanelState(bounds: CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY),
                          label: label, lines: sorted, lineHeight: computeLineHeight(from: sorted))
    }

    private static func elapsed(_ start: CFAbsoluteTime) -> Double {
        (CFAbsoluteTimeGetCurrent() - start) * 1000
    }
}
