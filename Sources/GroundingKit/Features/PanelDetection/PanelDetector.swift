import Vision
import CoreGraphics
import AppKit

/// Detects UI panels using Apple's RecognizeDocumentsRequest (WWDC25).
/// Each paragraph is detected with exact bounding box.
/// Paragraphs cluster naturally by X position into panels.
///
/// No color analysis, no ML models, no DBSCAN — just native Vision layout analysis.

public struct PanelRect: CustomStringConvertible {
    public let x: CGFloat
    public let y: CGFloat
    public let width: CGFloat
    public let height: CGFloat
    public let label: String
    public let paragraphCount: Int

    public init(x: CGFloat, y: CGFloat, width: CGFloat, height: CGFloat, label: String, paragraphCount: Int) {
        self.x = x
        self.y = y
        self.width = width
        self.height = height
        self.label = label
        self.paragraphCount = paragraphCount
    }

    public var description: String { "(\(Int(x)),\(Int(y))) \(Int(width))x\(Int(height)) [\(paragraphCount) paragraphs]" }
}

private struct Para {
    let rect: CGRect
    let text: String
}

@available(macOS 26.0, *)
struct PanelFinder {

    static func findPanels(in image: CGImage) async -> [PanelRect] {
        let imgSize = CGSize(width: image.width, height: image.height)
        let scale: CGFloat = 2.0

        let request = RecognizeDocumentsRequest()
        let handler = ImageRequestHandler(image)

        let observations: [DocumentObservation]
        do {
            observations = try await handler.perform(request)
        } catch {
            NSLog("PanelFinder: failed: %@", error.localizedDescription)
            return []
        }

        guard let doc = observations.first?.document else {
            NSLog("PanelFinder: No document")
            return []
        }

        let paragraphs: [Para] = doc.paragraphs.compactMap { p in
            let imgRect = p.boundingRegion.boundingBox.toImageCoordinates(imgSize, origin: .upperLeft)
            let logical = CGRect(
                x: imgRect.origin.x / scale,
                y: imgRect.origin.y / scale,
                width: imgRect.size.width / scale,
                height: imgRect.size.height / scale
            )
            // Skip tiny paragraphs (single chars, line numbers, OCR fragments)
            guard logical.width > 40 && logical.height > 10 else { return nil }
            // Skip very short text (likely OCR noise)
            guard p.transcript.count > 3 else { return nil }
            return Para(rect: logical, text: String(p.transcript.prefix(60)))
        }

        NSLog("PanelFinder: %d paragraphs (filtered from %d)", paragraphs.count, doc.paragraphs.count)

        // Step 2b: Find browser content band by Y-gap analysis
        // Collect all Y gaps > 25px — these separate OS chrome, browser content, terminal
        let sortedByY = paragraphs.sorted { $0.rect.midY < $1.rect.midY }
        struct YGap {
            let index: Int      // gap is between sortedByY[index-1] and sortedByY[index]
            let size: CGFloat
            let midY: CGFloat
        }
        var yGaps: [YGap] = []
        for i in 1..<sortedByY.count {
            let gap = sortedByY[i].rect.minY - sortedByY[i-1].rect.maxY
            if gap > 25 {
                let mid = (sortedByY[i-1].rect.maxY + sortedByY[i].rect.minY) / 2
                yGaps.append(YGap(index: i, size: gap, midY: mid))
                NSLog("PanelFinder: Y gap %.0fpx at y=%.0f", gap, mid)
            }
        }

        // Find the content band with widest X-spread (browser has left+right panels)
        // Bands are defined by consecutive Y gaps (plus screen top and bottom)
        var contentMinY: CGFloat = 0
        var contentMaxY = imgSize.height / scale
        var bestBandScore: CGFloat = 0

        let boundaries = [0] + yGaps.map { $0.index } + [sortedByY.count]
        for b in 0..<(boundaries.count - 1) {
            let startIdx = boundaries[b]
            let endIdx = boundaries[b + 1]
            let count = endIdx - startIdx
            guard count >= 5 else { continue }

            // Get paragraphs in this band
            let bandParas = Array(sortedByY[startIdx..<endIdx])
            let xPositions = bandParas.map { $0.rect.midX }
            let xSpread = (xPositions.max() ?? 0) - (xPositions.min() ?? 0)

            // Score: X-spread × paragraph count — browser content has wide spread + many paragraphs
            let score = xSpread * CGFloat(count)
            let bandMinY = b > 0 ? yGaps[b - 1].midY : CGFloat(0)
            let bandMaxY = b < yGaps.count ? yGaps[b].midY : imgSize.height / scale
            NSLog("PanelFinder: band y=%.0f..%.0f — %d paras, xSpread=%.0f, score=%.0f",
                  bandMinY, bandMaxY, count, xSpread, score)

            if score > bestBandScore {
                bestBandScore = score
                contentMinY = bandMinY
                contentMaxY = bandMaxY
            }
        }

        NSLog("PanelFinder: content band y=%.0f..%.0f (score=%.0f)",
              contentMinY, contentMaxY, bestBandScore)

        // Filter to content band only
        let contentParas = paragraphs.filter { $0.rect.midY > contentMinY && $0.rect.midY < contentMaxY }
        NSLog("PanelFinder: %d content paragraphs (filtered %d outside band)",
              contentParas.count, paragraphs.count - contentParas.count)

        let activeParagraphs = contentParas.isEmpty ? paragraphs : contentParas

        // Step 3: Find the natural X split — largest gap between paragraph X centers
        let xCenters = activeParagraphs.map { $0.rect.midX }.sorted()
        guard xCenters.count > 5 else {
            NSLog("PanelFinder: Too few paragraphs")
            return []
        }

        // Find all gaps > 40px, pick the one where both sides have ≥25% of paragraphs
        var bestGap: (mid: CGFloat, size: CGFloat) = (xCenters[xCenters.count/2], 0)
        let total = activeParagraphs.count

        for i in 1..<xCenters.count {
            let gap = xCenters[i] - xCenters[i-1]
            if gap > 40 {
                let mid = (xCenters[i-1] + xCenters[i]) / 2
                let leftCount = activeParagraphs.filter { $0.rect.midX < mid }.count
                let rightCount = activeParagraphs.filter { $0.rect.midX >= mid }.count
                let leftPct = CGFloat(leftCount) / CGFloat(total)
                let rightPct = CGFloat(rightCount) / CGFloat(total)

                // Both sides must have substantial content
                if leftPct >= 0.15 && rightPct >= 0.15 && gap > bestGap.size {
                    bestGap = (mid, gap)
                }
            }
        }

        guard bestGap.size > 0 else {
            NSLog("PanelFinder: No clear panel split found")
            // Return single panel covering everything
            let allRects = activeParagraphs.map { $0.rect }
            let bounds = boundingBox(of: allRects)
            return [PanelRect(x: bounds.minX, y: bounds.minY,
                              width: bounds.width, height: bounds.height,
                              label: "CONTENT", paragraphCount: activeParagraphs.count)]
        }

        let dividerX = bestGap.mid
        NSLog("PanelFinder: divider at x=%.0f (gap=%.0fpx)", dividerX, bestGap.size)

        // Step 4: Build independent panels from paragraph clusters
        let leftParas = activeParagraphs.filter { $0.rect.midX < dividerX }
        let rightParas = activeParagraphs.filter { $0.rect.midX >= dividerX }

        var panels: [PanelRect] = []

        if !leftParas.isEmpty {
            let bounds = boundingBox(of: leftParas.map { $0.rect })
            // Classify: is this question or code?
            let label = classifyPanel(leftParas)
            panels.append(PanelRect(x: bounds.minX, y: bounds.minY,
                                    width: bounds.width, height: bounds.height,
                                    label: label, paragraphCount: leftParas.count))
        }

        if !rightParas.isEmpty {
            let bounds = boundingBox(of: rightParas.map { $0.rect })
            let label = classifyPanel(rightParas)
            panels.append(PanelRect(x: bounds.minX, y: bounds.minY,
                                    width: bounds.width, height: bounds.height,
                                    label: label, paragraphCount: rightParas.count))
        }

        for p in panels {
            NSLog("PanelFinder: %@ — %@", p.label, p.description)
        }

        return panels
    }

    /// Classify a group of paragraphs as QUESTION or EDITOR
    private static func classifyPanel(_ paras: [Para]) -> String {
        var codeScore = 0
        var textScore = 0

        for p in paras {
            let t = p.text
            // Code indicators — syntax elements
            if t.contains("{") || t.contains("}") { codeScore += 3 }
            if t.contains(";") { codeScore += 2 }
            if t.contains("public") || t.contains("private") || t.contains("static") { codeScore += 3 }
            if t.contains("class ") || t.contains("int ") || t.contains("void ") { codeScore += 3 }
            if t.contains("return ") || t.contains("import ") || t.contains("new ") { codeScore += 2 }
            if t.contains("for (") || t.contains("if (") || t.contains("while (") { codeScore += 3 }
            if t.contains("(") && t.contains(")") { codeScore += 1 }
            if t.contains("->") || t.contains("=>") || t.contains("==") { codeScore += 2 }
            if t.contains("[]") || t.contains("()") { codeScore += 2 }
            // Indentation suggests code
            if t.hasPrefix("  ") || t.hasPrefix("\t") { codeScore += 1 }

            // Natural language indicators
            if t.contains("the ") || t.contains("is ") || t.contains("and ") { textScore += 1 }
            if t.contains("?") { textScore += 2 }
            if t.contains("Example") || t.contains("Question") || t.contains("Output") { textScore += 2 }
            if t.contains("Given ") || t.contains("Find ") || t.contains("Write ") { textScore += 2 }
            let wordCount = t.split(separator: " ").count
            if wordCount > 8 { textScore += 2 }
            else if wordCount > 5 { textScore += 1 }
        }

        NSLog("PanelFinder: classify — code=%d text=%d → %@",
              codeScore, textScore, codeScore > textScore ? "EDITOR" : "QUESTION")
        return codeScore > textScore ? "EDITOR" : "QUESTION"
    }

    /// Compute bounding box of a set of CGRects
    private static func boundingBox(of rects: [CGRect]) -> CGRect {
        guard !rects.isEmpty else { return .zero }
        let minX = rects.map { $0.minX }.min()!
        let minY = rects.map { $0.minY }.min()!
        let maxX = rects.map { $0.maxX }.max()!
        let maxY = rects.map { $0.maxY }.max()!
        return CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
    }
}
