import Vision
import CoreGraphics
import AppKit

/// Panel detection using VNGenerateObjectnessBasedSaliencyImageRequest.
/// Each panel is found INDEPENDENTLY by its own visual salience + content classification.
///
/// Pipeline: Saliency (~160ms) → filter → classify each crop (OCR .fast ~30ms) → deduplicate

@available(macOS 14.0, *)
struct FastPanelFinder {

    static func findPanels(in image: CGImage) -> [PanelRect] {
        let imgW = CGFloat(image.width)
        let imgH = CGFloat(image.height)
        let scale: CGFloat = 2.0
        let logicalW = imgW / scale
        let logicalH = imgH / scale

        // --- Step 1: Find salient regions ---
        let saliencyRequest = VNGenerateObjectnessBasedSaliencyImageRequest()

        let handler = VNImageRequestHandler(cgImage: image, options: [:])
        do {
            try handler.perform([saliencyRequest])
        } catch {
            NSLog("FastPanel: saliency error: %@", error.localizedDescription)
            return []
        }

        guard let saliencyObs = saliencyRequest.results?.first as? VNSaliencyImageObservation else {
            NSLog("FastPanel: no saliency observation")
            return []
        }

        guard let salientObjects = saliencyObs.salientObjects, !salientObjects.isEmpty else {
            NSLog("FastPanel: 0 salient objects")
            return []
        }

        NSLog("FastPanel: %d salient objects", salientObjects.count)

        // --- Step 2: Convert and filter ---
        struct Candidate {
            let rect: CGRect       // logical screen coords
            let pixelRect: CGRect  // backing pixel coords for cropping
            let confidence: Float
        }

        var candidates: [Candidate] = []

        for obj in salientObjects {
            let box = obj.boundingBox  // normalized, bottom-left origin

            let logicalRect = CGRect(
                x: box.origin.x * logicalW,
                y: (1.0 - box.origin.y - box.height) * logicalH,
                width: box.width * logicalW,
                height: box.height * logicalH
            )

            let pixelRect = CGRect(
                x: box.origin.x * imgW,
                y: (1.0 - box.origin.y - box.height) * imgH,
                width: box.width * imgW,
                height: box.height * imgH
            ).integral

            NSLog("  salient: (%.0f,%.0f) %.0fx%.0f conf=%.2f",
                  logicalRect.minX, logicalRect.minY,
                  logicalRect.width, logicalRect.height, obj.confidence)

            // Filter: minimum panel size
            guard logicalRect.width >= 150 && logicalRect.height >= 100 else { continue }
            // Filter: not the entire screen
            guard logicalRect.width < logicalW * 0.9 || logicalRect.height < logicalH * 0.9 else { continue }

            candidates.append(Candidate(rect: logicalRect, pixelRect: pixelRect, confidence: obj.confidence))
        }

        NSLog("FastPanel: %d candidates after filter", candidates.count)

        // --- Step 3: Classify each candidate independently by content ---
        var panels: [PanelRect] = []

        for c in candidates {
            // Crop image to this salient region
            let imgRect = CGRect(x: 0, y: 0, width: image.width, height: image.height)
            let safeCrop = c.pixelRect.intersection(imgRect)
            guard !safeCrop.isEmpty, safeCrop.width > 100, safeCrop.height > 100 else { continue }
            guard let cropped = image.cropping(to: safeCrop) else { continue }

            let label = classifyByContent(image: cropped)
            guard let label = label else { continue }

            panels.append(PanelRect(
                x: c.rect.minX, y: c.rect.minY,
                width: c.rect.width, height: c.rect.height,
                label: label, paragraphCount: 0
            ))
            NSLog("FastPanel: %@ — (%.0f,%.0f) %.0fx%.0f conf=%.2f",
                  label, c.rect.minX, c.rect.minY, c.rect.width, c.rect.height, c.confidence)
        }

        // --- Step 4: Deduplicate — keep largest per label ---
        var bestByLabel: [String: PanelRect] = [:]
        for p in panels {
            let area = p.width * p.height
            let existingArea = (bestByLabel[p.label].map { $0.width * $0.height }) ?? 0
            if area > existingArea {
                bestByLabel[p.label] = p
            }
        }

        return Array(bestByLabel.values).sorted { $0.x < $1.x }
    }

    /// Classify a cropped region by running fast OCR and scoring code vs natural language.
    private static func classifyByContent(image: CGImage) -> String? {
        let textRequest = VNRecognizeTextRequest()
        textRequest.recognitionLevel = .fast
        textRequest.usesLanguageCorrection = false

        let handler = VNImageRequestHandler(cgImage: image, options: [:])
        do {
            try handler.perform([textRequest])
        } catch {
            return nil
        }

        let texts = textRequest.results?.compactMap { $0.topCandidates(1).first?.string } ?? []
        guard texts.count >= 2 else { return nil }  // need enough text to classify

        var codeScore = 0
        var textScore = 0

        for t in texts {
            // Code syntax
            if t.contains("{") || t.contains("}") { codeScore += 3 }
            if t.contains(";") { codeScore += 2 }
            if t.contains("public") || t.contains("private") || t.contains("static") { codeScore += 3 }
            if t.contains("class ") || t.contains("int ") || t.contains("void ") { codeScore += 3 }
            if t.contains("return ") || t.contains("import ") || t.contains("new ") { codeScore += 2 }
            if t.contains("for (") || t.contains("if (") || t.contains("while (") { codeScore += 3 }
            if t.contains("->") || t.contains("=>") || t.contains("==") { codeScore += 2 }
            if t.contains("(") && t.contains(")") { codeScore += 1 }

            // Natural language
            if t.contains("the ") || t.contains("is ") || t.contains("and ") { textScore += 1 }
            if t.contains("?") { textScore += 2 }
            if t.contains("Example") || t.contains("Question") || t.contains("Output") { textScore += 2 }
            if t.contains("Given ") || t.contains("Find ") || t.contains("Write ") { textScore += 2 }
            let wordCount = t.split(separator: " ").count
            if wordCount > 8 { textScore += 2 }
            else if wordCount > 5 { textScore += 1 }
        }

        NSLog("  classify: %d texts, code=%d text=%d", texts.count, codeScore, textScore)

        guard codeScore + textScore >= 3 else { return nil }
        return codeScore > textScore ? "EDITOR" : "QUESTION"
    }
}
