import AppKit
import Vision
import CoreGraphics

/// Screen capture + Vision text detection.
/// Plain NSObject — no @MainActor, no async, no concurrency issues.
/// Timer calls tick() on main thread → captures screen → Vision on background → updates overlay.
public final class ScreenCapture: NSObject {
    private let overlayController: OverlayController
    private var cycleCount = 0
    private var processing = false
    private let visionQueue = DispatchQueue(label: "ghost.vision", qos: .userInteractive)

    public init(overlayController: OverlayController) {
        self.overlayController = overlayController
        super.init()
    }

    /// Called by Timer on main run loop. Captures screen, dispatches Vision to background.
    @objc public func tick() {
        guard !processing else { return }
        processing = true

        let image = CGWindowListCreateImage(
            CGRect.infinite, .optionOnScreenOnly, kCGNullWindowID, []
        )
        guard let image else {
            processing = false
            return
        }

        let t0 = CFAbsoluteTimeGetCurrent()
        let cycle = cycleCount

        visionQueue.async {
            let request = VNRecognizeTextRequest()
            request.recognitionLevel = .fast
            request.usesLanguageCorrection = false

            try? VNImageRequestHandler(cgImage: image, orientation: .up).perform([request])

            let observations = (request.results as? [VNRecognizedTextObservation]) ?? []
            let ms = Int((CFAbsoluteTimeGetCurrent() - t0) * 1000)

            let blocks = observations.compactMap { obs -> TextBlock? in
                guard let c = obs.topCandidates(1).first else { return nil }
                let b = obs.boundingBox
                return TextBlock(text: c.string, confidence: c.confidence,
                                 x: b.origin.x, y: b.origin.y,
                                 width: b.size.width, height: b.size.height)
            }

            let filtered = Self.filterToCode(blocks)
            let n = cycle + 1

            if n <= 20 || n % 10 == 0 {
                NSLog("Cycle %d: %dms, %d → %d", n, ms, blocks.count, filtered.count)
            }

            DispatchQueue.main.async { [self] in
                self.cycleCount = n
                self.processing = false
                self.overlayController.updateTextBlocks(filtered)
            }
        }
    }

    /// Filter blocks to code lines only. Uses position + content heuristics.
    static func filterToCode(_ blocks: [TextBlock]) -> [TextBlock] {
        // Step 1: Remove obvious non-code
        let cleaned = blocks.filter { b in
            let t = b.text.trimmingCharacters(in: .whitespaces)
            if t.count < 3 { return false }
            if t.allSatisfy({ $0.isNumber || $0 == "." }) { return false }

            // Common UI chrome/noise to skip when scanning for platform-relevant text.
            // Generic entries cover browser + OS chrome; site-specific entries can be added
            // via site configuration downstream.
            let skip = ["Chrome","File","Edit","View","Window","Help",
                        "Bookmarks","Profiles","Tab","History",
                        "Run","Submit","Compile","Tests",
                        "Output","Console","Terminal","Local",
                        "Description","Solutions","Submissions",
                        "Question","Language",
                        "Change Theme","Exit Full","Upload",
                        "Navigate","Refactor","Build","Tools","Git",
                        "Fri ","Mon ","Tue ","Wed ","Thu ","Sat ","Sun ",
                        "localhost","http://",
                        "Running","timeout","Bash","ctrl+",
                        "Cycle","heartbeat","token"]
            for kw in skip {
                if t.localizedCaseInsensitiveContains(kw) { return false }
            }
            return true
        }

        // Step 2: Classify as code vs natural language
        // Code has: brackets, semicolons, operators, indentation patterns
        let codeBlocks = cleaned.filter { b in
            let t = b.text
            let codeIndicators = [
                t.contains("{") || t.contains("}") || t.contains(";"),
                t.contains("(") && t.contains(")"),
                t.range(of: #"\b(int|void|public|private|class|return|for|if|else|new|import|static|String|Integer|boolean)\b"#, options: .regularExpression) != nil,
                t.range(of: #"[a-zA-Z]+\.[a-zA-Z]+\("#, options: .regularExpression) != nil,
                t.range(of: #"[a-zA-Z_]\w*\s*="#, options: .regularExpression) != nil,
                t.hasPrefix("//"),
            ]
            let score = codeIndicators.filter { $0 }.count
            return score >= 1  // At least 1 code indicator
        }

        // Step 3: If we have code blocks, find their X cluster (editor column)
        // and only keep blocks in that cluster
        guard !codeBlocks.isEmpty else { return cleaned }

        let codeAvgX = codeBlocks.map { $0.x }.reduce(0, +) / CGFloat(codeBlocks.count)

        // Keep blocks near the code cluster X AND in the upper 75% of screen
        // (excludes terminal/dock at the bottom)
        return cleaned.filter { b in
            abs(b.x - codeAvgX) < 0.2 && b.y > 0.15  // Vision y: 0=bottom, 1=top
        }
    }
}
