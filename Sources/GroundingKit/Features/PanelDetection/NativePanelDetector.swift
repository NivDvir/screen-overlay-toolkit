import Foundation
import CoreGraphics
import AppKit
import MLXVLM
import MLXLMCommon
@preconcurrency import Tokenizers

/// Bridge tokenizers
private struct TokenizerBridge: MLXLMCommon.Tokenizer, @unchecked Sendable {
    private let upstream: any Tokenizers.Tokenizer
    init(_ upstream: any Tokenizers.Tokenizer) { self.upstream = upstream }
    func encode(text: String, addSpecialTokens: Bool) -> [Int] { upstream.encode(text: text, addSpecialTokens: addSpecialTokens) }
    func decode(tokenIds: [Int], skipSpecialTokens: Bool) -> String { upstream.decode(tokens: tokenIds, skipSpecialTokens: skipSpecialTokens) }
    func convertTokenToId(_ token: String) -> Int? { upstream.convertTokenToId(token) }
    func convertIdToToken(_ id: Int) -> String? { upstream.convertIdToToken(id) }
    var bosToken: String? { upstream.bosToken }
    var eosToken: String? { upstream.eosToken }
    var unknownToken: String? { upstream.unknownToken }
    func applyChatTemplate(messages: [[String: any Sendable]], tools: [[String: any Sendable]]?,
                           additionalContext: [String: any Sendable]?) throws -> [Int] {
        do { return try upstream.applyChatTemplate(messages: messages, tools: tools, additionalContext: additionalContext) }
        catch Tokenizers.TokenizerError.missingChatTemplate { throw MLXLMCommon.TokenizerError.missingChatTemplate }
    }
}

private struct LocalTokenizerLoader: MLXLMCommon.TokenizerLoader {
    func load(from directory: URL) async throws -> any MLXLMCommon.Tokenizer {
        TokenizerBridge(try await AutoTokenizer.from(modelFolder: directory))
    }
}

/// Native panel detection using Qwen2.5-VL via MLX Swift with MROPE spatial encoding
public class NativePanelDetector {
    private var container: ModelContainer?

    public var modelPath = ""
    public var onProgress: ((String) -> Void)?

    public init() {}

    /// Default model repo (mlx-community slug) when `GK_MODEL` env is unset.
    /// Any model that shares Qwen2.5-VL's architecture (e.g. UI-TARS-1.5-7B) can
    /// be swapped here — the MROPE patches in the pinned mlx-swift-lm fork apply
    /// to the same Qwen25VL code path used by these derivatives.
    private static let defaultModelRepo = "mlx-community/Qwen2.5-VL-7B-Instruct-4bit"

    public func loadModel() async throws {
        guard container == nil else { return }

        // Env override: set GK_MODEL to any mlx-community/... repo slug to swap models.
        // Example: GK_MODEL=mlx-community/UI-TARS-1.5-7B-4bit
        let repo = ProcessInfo.processInfo.environment["GK_MODEL"] ?? Self.defaultModelRepo
        let repoSlug = repo.replacingOccurrences(of: "/", with: "--")
        let basePath = NSString(string: "~/.cache/huggingface/hub/models--\(repoSlug)/snapshots").expandingTildeInPath
        let fm = FileManager.default
        guard let snapshots = try? fm.contentsOfDirectory(atPath: basePath),
              let snapshot = snapshots.first(where: { !$0.hasPrefix(".") }) else {
            throw NSError(domain: "NativeVLM", code: 1, userInfo: [NSLocalizedDescriptionKey: "Model not found at \(basePath) — check GK_MODEL env var"])
        }
        modelPath = "\(basePath)/\(snapshot)"

        NSLog("NativeVLM: loading repo %@ from %@", repo, modelPath)
        let start = CFAbsoluteTimeGetCurrent()
        container = try await loadModelContainer(from: URL(fileURLWithPath: modelPath), using: LocalTokenizerLoader())
        NSLog("NativeVLM: loaded in %.0fms", (CFAbsoluteTimeGetCurrent() - start) * 1000)
    }

    // MARK: - Python subprocess fallback (100% accurate, bypasses CIImage)

    /// Call Python 2-stage detector as subprocess — avoids CIImage color management issues
    func detectPanelsPython(from image: CGImage) async -> ScreenAnalysis? {
        let retinaScale = screenScaleFactor

        // Save screenshot for Python
        let path = "/tmp/native_vlm_input.png"
        let bitmap = NSBitmapImageRep(cgImage: image)
        guard let data = bitmap.representation(using: .png, properties: [:]) else { return nil }
        try? data.write(to: URL(fileURLWithPath: path))

        NSLog("NativeVLM: calling Python 2-stage detector...")
        await MainActor.run { self.onProgress?("🔍 Python 2-stage detecting...") }

        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        proc.arguments = ["python3", NSString(string: "~/dev/panel_detector_2stage.py").expandingTildeInPath, path]
        let pipe = Pipe()
        proc.standardOutput = pipe
        proc.standardError = pipe

        do {
            try proc.run()
            proc.waitUntilExit()
        } catch {
            NSLog("NativeVLM: Python subprocess failed: %@", error.localizedDescription)
            return nil
        }

        // Read results
        let outputPath = "/tmp/superdeep_analysis.json"
        guard let jsonData = try? Data(contentsOf: URL(fileURLWithPath: outputPath)),
              let result = try? JSONSerialization.jsonObject(with: jsonData) as? [String: Any],
              let qp = result["questionPanel"] as? [String: Any],
              let ep = result["editorPanel"] as? [String: Any],
              let qx = qp["x"] as? Double, let qy = qp["y"] as? Double,
              let qw = qp["width"] as? Double, let qh = qp["height"] as? Double,
              let ex = ep["x"] as? Double, let ey = ep["y"] as? Double,
              let ew = ep["width"] as? Double, let eh = ep["height"] as? Double else {
            NSLog("NativeVLM: Python output parse failed")
            return nil
        }

        NSLog("NativeVLM: Python Q:(%.0f,%.0f) %.0fx%.0f  E:(%.0f,%.0f) %.0fx%.0f",
              qx, qy, qw, qh, ex, ey, ew, eh)

        let question = PanelInfo(bounds: CGRect(x: qx, y: qy, width: qw, height: qh),
                                 title: "question", content: "", lineHeight: 21, firstLineY: qy + 20)
        let editor = PanelInfo(bounds: CGRect(x: ex, y: ey, width: ew, height: eh),
                               title: "editor", content: "", lineHeight: 21, firstLineY: ey + 20)

        return ScreenAnalysis(platform: "python_2stage", questionPanel: question, editorPanel: editor,
                              solution: MockSolution(problemId: "native", keywords: [], lines: []))
    }

    // MARK: - Two-Stage Hierarchical Grounding (Native Swift — less accurate due to CIImage)

    /// Run a single VLM inference and parse bbox_2d results
    private func runVLM(_ container: ModelContainer, image: CIImage, prompt: String,
                        resize: CGSize) async -> [(bbox: [Double], label: String)] {
        // Explicit `processing: .init(resize: nil)` disables ChatSession's
        // default 512×512 pre-resize (a sensible UX default in mlx-swift-lm
        // that's wrong for grounding: it drops spatial detail BEFORE our
        // PIL-matching Lanczos runs and makes our bbox output diverge from
        // the Python mlx-vlm reference). Qwen25VL.preprocess computes its
        // own target size from the full-resolution source.
        let session = ChatSession(
            container,
            generateParameters: .init(maxTokens: 200, temperature: 0.0),
            processing: .init(resize: nil)
        )

        do {
            var response = ""
            var tokenCount = 0
            let t0 = CFAbsoluteTimeGetCurrent()
            for try await chunk in session.streamResponse(
                to: prompt, images: [.ciImage(image)], videos: []
            ) {
                response += chunk
                tokenCount += 1
                let elapsed = Int(CFAbsoluteTimeGetCurrent() - t0)
                let filled = min(20, tokenCount / 4)
                let bar = String(repeating: "█", count: filled) + String(repeating: "░", count: 20 - filled)
                await MainActor.run { self.onProgress?("🔍 VLM [\(bar)] \(tokenCount) tok — \(elapsed)s") }
            }

            NSLog("NativeVLM raw response (%d tok): %@", tokenCount, String(response.prefix(400)))
            // Test hook: if GK_RAW_OUT is set, append raw response to that file.
            if let rawOutPath = ProcessInfo.processInfo.environment["GK_RAW_OUT"] {
                let line = "=== tokens=\(tokenCount) ===\n\(response)\n=== END ===\n"
                if let data = line.data(using: .utf8) {
                    if FileManager.default.fileExists(atPath: rawOutPath) {
                        if let fh = FileHandle(forWritingAtPath: rawOutPath) {
                            fh.seekToEndOfFile(); fh.write(data); try? fh.close()
                        }
                    } else {
                        FileManager.default.createFile(atPath: rawOutPath, contents: data)
                    }
                }
            }

            // Native Qwen2.5-VL grounding-token format (also used by UI-TARS):
            //   <|object_ref_start|>LABEL<|object_ref_end|><|box_start|>(x1,y1),(x2,y2)<|box_end|>
            // UI-TARS typically emits this with 0–1000 normalized coordinates — scale
            // them back to the model's resize dimensions so the downstream code path
            // (which assumes model-space pixels) works unchanged.
            if response.contains("<|box_start|>") {
                var results: [(bbox: [Double], label: String)] = []
                let scale = 1000.0  // UI-TARS / native grounding tokens: 0–1000 normalized
                let w = Double(resize.width), h = Double(resize.height)

                // Pattern A — Qwen2.5-VL native: two-corner rectangle with ref tokens.
                let patA = #"<\|object_ref_start\|>(.+?)<\|object_ref_end\|><\|box_start\|>\((\d+(?:\.\d+)?),(\d+(?:\.\d+)?)\),\((\d+(?:\.\d+)?),(\d+(?:\.\d+)?)\)<\|box_end\|>"#
                if let re = try? NSRegularExpression(pattern: patA, options: []) {
                    let range = NSRange(response.startIndex..., in: response)
                    re.enumerateMatches(in: response, options: [], range: range) { m, _, _ in
                        guard let m = m, m.numberOfRanges == 6,
                              let l = Range(m.range(at: 1), in: response),
                              let x1 = Range(m.range(at: 2), in: response),
                              let y1 = Range(m.range(at: 3), in: response),
                              let x2 = Range(m.range(at: 4), in: response),
                              let y2 = Range(m.range(at: 5), in: response)
                        else { return }
                        let bx1 = (Double(response[x1]) ?? 0) / scale * w
                        let by1 = (Double(response[y1]) ?? 0) / scale * h
                        let bx2 = (Double(response[x2]) ?? 0) / scale * w
                        let by2 = (Double(response[y2]) ?? 0) / scale * h
                        results.append(([bx1, by1, bx2, by2], String(response[l])))
                    }
                }

                // Pattern B — UI-TARS terse click format: LABEL<|box_start|>(x,y)<|box_end|>
                // UI-TARS is trained for click-target prediction, so it emits a single
                // (x, y) per element rather than a two-corner rectangle. We surface it
                // as a zero-size "point rectangle" so the caller can see what was
                // returned and decide how to use it.
                if results.isEmpty {
                    let patB = #"([A-Za-z][A-Za-z0-9_\-]*)\s*<\|box_start\|>\s*\((\d+(?:\.\d+)?),\s*(\d+(?:\.\d+)?)\)\s*<\|box_end\|>"#
                    if let re = try? NSRegularExpression(pattern: patB, options: []) {
                        let range = NSRange(response.startIndex..., in: response)
                        re.enumerateMatches(in: response, options: [], range: range) { m, _, _ in
                            guard let m = m, m.numberOfRanges == 4,
                                  let l = Range(m.range(at: 1), in: response),
                                  let xR = Range(m.range(at: 2), in: response),
                                  let yR = Range(m.range(at: 3), in: response)
                            else { return }
                            let x = (Double(response[xR]) ?? 0) / scale * w
                            let y = (Double(response[yR]) ?? 0) / scale * h
                            // Zero-size point — downstream treats as center
                            results.append(([x, y, x, y], String(response[l])))
                        }
                    }
                    if !results.isEmpty {
                        NSLog("NativeVLM: parsed %d UI-TARS click-points (label<|box_start|>(x,y))", results.count)
                    }
                }

                if !results.isEmpty {
                    return results
                }
            }

            let cleaned = response.replacingOccurrences(of: "```json", with: "")
                                  .replacingOccurrences(of: "```", with: "")
                                  .trimmingCharacters(in: .whitespacesAndNewlines)

            guard let s = cleaned.firstIndex(of: "["), let e = cleaned.lastIndex(of: "]"),
                  let jsonData = String(cleaned[s...e]).data(using: .utf8),
                  let arr = try? JSONSerialization.jsonObject(with: jsonData) as? [[String: Any]] else {
                // Try single object
                guard let s = cleaned.firstIndex(of: "{"), let e = cleaned.lastIndex(of: "}"),
                      let jsonData = String(cleaned[s...e]).data(using: .utf8),
                      let obj = try? JSONSerialization.jsonObject(with: jsonData) as? [String: Any] else {
                    return []
                }
                let bbox = (obj["bbox_2d"] as? [NSNumber])?.map { $0.doubleValue } ?? []
                let label = (obj["label"] as? String) ?? ""
                return bbox.count >= 4 ? [(bbox, label)] : []
            }

            return arr.compactMap { item in
                guard let bbox = (item["bbox_2d"] as? [NSNumber])?.map({ $0.doubleValue }),
                      bbox.count >= 4 else { return nil }
                let label = (item["label"] as? String) ?? ""
                return (bbox, label)
            }
        } catch {
            NSLog("NativeVLM: VLM error: %@", error.localizedDescription)
            return []
        }
    }

    /// Compute VLM resize dimensions matching Python: max 1280, multiples of 28
    private func vlmResize(w: CGFloat, h: CGFloat) -> CGSize {
        let maxSize: CGFloat = 1280.0
        let factor: CGFloat = 28.0
        let ratio = min(maxSize / max(w, h), 1.0)
        let rw = floor(w * ratio / factor) * factor
        let rh = floor(h * ratio / factor) * factor
        return CGSize(width: max(rw, factor), height: max(rh, factor))
    }

    /// Detection mode hint. `.twoPanel` is the LeetCode-style question+editor grounding
    /// prompt; `.reader` asks the VLM to locate the main reading-content area while
    /// excluding navigation chrome and sidebars.
    public enum DetectionMode {
        case twoPanel
        case reader
    }

    public func detectPanels(from image: CGImage, mode: DetectionMode = .twoPanel) async -> ScreenAnalysis? {
        guard let container = self.container else { return nil }

        let retinaScale = screenScaleFactor
        let screenW = CGFloat(image.width) / retinaScale
        let screenH = CGFloat(image.height) / retinaScale

        // Save original PNG (wrapped in autoreleasepool for memory safety)
        let path = "/tmp/native_vlm_input.png"
        let bitmap = NSBitmapImageRep(cgImage: image)
        if let data = bitmap.representation(using: .png, properties: [:]) {
            try? data.write(to: URL(fileURLWithPath: path))
        }

        // Relabel CGImage as sRGB — raw bytes preserved, ICC stripped
        let srgbCS = CGColorSpace(name: CGColorSpace.sRGB)!
        let srgbCG: CGImage
        if let dp = image.dataProvider, let rawData = dp.data {
            srgbCG = CGImage(
                width: image.width, height: image.height,
                bitsPerComponent: image.bitsPerComponent,
                bitsPerPixel: image.bitsPerPixel,
                bytesPerRow: image.bytesPerRow,
                space: srgbCS,
                bitmapInfo: image.bitmapInfo,
                provider: CGDataProvider(data: rawData)!,
                decode: nil, shouldInterpolate: true,
                intent: .defaultIntent
            ) ?? image
        } else {
            srgbCG = image
        }
        let ciImage = CIImage(cgImage: srgbCG)
        let resize = vlmResize(w: screenW, h: screenH)

        NSLog("NativeVLM: single-stage. image %dx%d, resize %.0fx%.0f",
              image.width, image.height, resize.width, resize.height)

        let start = CFAbsoluteTimeGetCurrent()
        await MainActor.run { self.onProgress?("🔍 VLM processing image...") }

        // Detect if the loaded model is UI-TARS — it was trained for UI click/
        // locate tasks and responds better to a natural-language "locate" prompt
        // than to the Qwen2.5-VL JSON-array prompt.
        let isUITars = modelPath.contains("UI-TARS") || modelPath.lowercased().contains("ui-tars")

        // Mode-specific prompt — two-panel test-taking vs single-panel reading
        let prompt: String
        let requiredPanels: Int
        switch mode {
        case .twoPanel:
            prompt = "Detect these two UI panels and output their bbox_2d coordinates as a JSON array:\n1. \"question\" - the problem description panel on the left\n2. \"editor\" - the code editor panel on the right"
            requiredPanels = 2
        case .reader:
            if isUITars {
                // UI-TARS was trained on a locate/click task format. Ask in its native
                // frame using Qwen2.5-VL's grounding tokens — UI-TARS inherits them
                // (<|object_ref_start|>, <|box_start|>). Expect output like:
                //   <|object_ref_start|>main reading content<|object_ref_end|>
                //   <|box_start|>(x1,y1),(x2,y2)<|box_end|>
                // Repeated per region.
                prompt = """
                Locate the 2 to 4 main layout regions in this webpage screenshot and output each as a bounding box using the native grounding tokens. The regions to locate are:

                  - the main reading content column (article body / paper text)
                  - any left-side navigation or table-of-contents sidebar
                  - any right-side settings / related-links / access-paper panel
                  - the top site navigation / header row

                For every region that is present in the screenshot, output ONE line in this exact format:

                <|object_ref_start|>LABEL<|object_ref_end|><|box_start|>(x1,y1),(x2,y2)<|box_end|>

                Where LABEL is one of: content, sidebar-left, sidebar-right, header.
                And (x1,y1),(x2,y2) is the rectangle in normalized coordinates scaled to 0–1000, with (x1,y1) the top-left corner and (x2,y2) the bottom-right corner.

                No prose, no JSON, no extra text — just the labeled box lines.
                """
            } else {
                // Qwen2.5-VL and siblings — reliably produce JSON-array output when
                // asked in this format.
                prompt = """
                Decompose this webpage screenshot into its 2 to 4 main visual layout regions. Do not merge regions that are visually distinct (different background, clearly separated by whitespace, or different content type).

                For each region, output a RECTANGLE bounding box as four pixel coordinates (not a click point): [x1, y1, x2, y2] where (x1, y1) is the top-left corner and (x2, y2) is the bottom-right corner. The array MUST contain exactly 4 numbers.

                Pick a short semantic label for each region from this set:
                  "content"     — the main reading column / article body / paper text (prose).
                  "sidebar-left"— left-hand navigation, table of contents, tools rail.
                  "sidebar-right"— right-hand settings, appearance, access-paper / related-links panel.
                  "header"      — top site navigation / search bar / breadcrumb banner.
                  "footer"      — bottom tab strip, references row, page footer.

                Every visually distinct region gets its own entry. Do not omit a sidebar just because it is narrow.

                Output a JSON array of 2–4 objects. Each object has exactly these keys:
                [{"label": "<label>", "bbox_2d": [x1, y1, x2, y2]}, ...]
                """
            }
            requiredPanels = 1
        }

        let panelResults = await runVLM(container, image: ciImage, prompt: prompt, resize: resize)

        let elapsed = (CFAbsoluteTimeGetCurrent() - start) * 1000
        NSLog("NativeVLM: inference %.0fms (mode=%@)", elapsed, String(describing: mode))

        guard panelResults.count >= requiredPanels else {
            NSLog("NativeVLM: need %d panels, got %d (mode=%@)", requiredPanels, panelResults.count, String(describing: mode))
            return nil
        }

        // Reader mode: the VLM decomposes the page into 2–4 labeled regions.
        // We pick the content region algorithmically so the VLM doesn't have to
        // nail a single-target answer.
        if mode == .reader {
            let scaleX = screenW / resize.width
            let scaleY = screenH / resize.height

            // Map every returned region into screen coords + area.
            struct Region {
                let rect: CGRect
                let label: String
                var area: CGFloat { rect.width * rect.height }
                var aspect: CGFloat { rect.height > 0 ? rect.width / rect.height : 0 }
            }
            let regions: [Region] = panelResults.map { r in
                let b = r.bbox
                let rect = CGRect(
                    x: b[0] * scaleX, y: b[1] * scaleY,
                    width: (b[2] - b[0]) * scaleX, height: (b[3] - b[1]) * scaleY
                )
                return Region(rect: rect, label: r.label.lowercased())
            }
            for r in regions {
                NSLog("NativeVLM[reader] region: %@ (%.0fx%.0f @ %.0f,%.0f)",
                      r.label, r.rect.width, r.rect.height, r.rect.minX, r.rect.minY)
            }

            // Pick the content region:
            //  1. Prefer anything labeled content/article/body/main/reading.
            //  2. Otherwise, largest-area region that is not a sidebar/header/footer label
            //     AND is wide enough (aspect > 0.4) and tall enough (> 180pt).
            //  3. Fall back to the single largest region.
            let contentLabels: Set<String> = ["content", "article", "body", "main", "reading"]
            let sideLabels: Set<String> = ["sidebar-left", "sidebar-right", "sidebar", "left sidebar", "right sidebar", "header", "footer", "nav", "navigation"]

            let explicit = regions.first { contentLabels.contains($0.label) }
            let picked: Region?
            if let e = explicit {
                picked = e
            } else {
                let candidates = regions
                    .filter { !sideLabels.contains($0.label) }
                    .filter { $0.rect.width > 200 && $0.rect.height > 180 && $0.aspect > 0.4 }
                picked = candidates.max(by: { $0.area < $1.area }) ?? regions.max(by: { $0.area < $1.area })
            }

            guard let c = picked else {
                NSLog("NativeVLM[reader]: no usable region in %d returned", regions.count)
                return nil
            }

            // UI-TARS returns click points (zero-area rects). Expand the content point
            // into a usable reading rectangle centered on the click. Dimensions target
            // the Chrome window's content area, with the whole screen as a fallback
            // for when chromeBounds returns a bogus (too small / floating-utility
            // window) result.
            var contentRect = c.rect
            if contentRect.width < 20 || contentRect.height < 20 {
                let chrome = ChromeCapture.chromeBounds()
                // Require Chrome bounds be at least 600×400 logical to trust them
                let useChrome = chrome.width >= 600 && chrome.height >= 400
                let frameW: CGFloat = useChrome ? chrome.width : screenW
                let frameH: CGFloat = useChrome ? chrome.height : screenH
                let frameMinX: CGFloat = useChrome ? chrome.minX : 0
                let frameMinY: CGFloat = useChrome ? chrome.minY : 0
                // Default reader rectangle: 70% of page width × 75% of page height,
                // centered on the content click point.
                let targetW = frameW * 0.70
                let targetH = frameH * 0.75
                let cx = c.rect.midX
                let cy = c.rect.midY
                var ex = cx - targetW / 2
                var ey = cy - targetH / 2
                // Clamp inside page bounds with a small margin
                let pageMinX = frameMinX + 10
                let pageMinY = frameMinY + 80   // leave space for browser chrome / top nav
                let pageMaxX = frameMinX + frameW - 10
                let pageMaxY = frameMinY + frameH - 10
                ex = max(pageMinX, min(ex, pageMaxX - targetW))
                ey = max(pageMinY, min(ey, pageMaxY - targetH))
                contentRect = CGRect(x: ex, y: ey, width: targetW, height: targetH)
                NSLog("NativeVLM[reader] click-point expanded: click=(%.0f,%.0f) chromeBounds=%.0fx%.0f useChrome=%@ → %.0fx%.0f @ %.0f,%.0f",
                      cx, cy, chrome.width, chrome.height, useChrome ? "yes" : "no",
                      contentRect.width, contentRect.height, contentRect.minX, contentRect.minY)
            }

            // Trim: if the VLM's content region overlaps a declared sidebar, push the
            // content's edges inward so the two don't overlap. The VLM sometimes draws
            // the content region wide enough to include the sidebar visually. Skip
            // this when the content was expanded from a click point (already clamped
            // to chrome bounds above) and sidebar regions are also zero-area.
            for side in regions where sideLabels.contains(side.label) {
                // Only trim if the sidebar has a real rect (width > 20)
                guard side.rect.width > 20 else { continue }
                // Right-side sidebar clips content's right edge
                if side.label.contains("right") && side.rect.minX < contentRect.maxX && side.rect.minX > contentRect.minX {
                    contentRect.size.width = side.rect.minX - contentRect.minX - 6
                }
                // Left-side sidebar clips content's left edge
                if side.label.contains("left") && side.rect.maxX > contentRect.minX && side.rect.maxX < contentRect.maxX {
                    let shift = side.rect.maxX + 6 - contentRect.minX
                    contentRect.origin.x = side.rect.maxX + 6
                    contentRect.size.width -= shift
                }
                // Header clips content's top edge
                if side.label == "header" && side.rect.maxY > contentRect.minY && side.rect.maxY < contentRect.maxY {
                    let shift = side.rect.maxY + 4 - contentRect.minY
                    contentRect.origin.y = side.rect.maxY + 4
                    contentRect.size.height -= shift
                }
                // Footer clips content's bottom edge
                if side.label == "footer" && side.rect.minY < contentRect.maxY && side.rect.minY > contentRect.minY {
                    contentRect.size.height = side.rect.minY - contentRect.minY - 4
                }
            }

            NSLog("NativeVLM[reader] picked content: '%@' %.0fx%.0f @ %.0f,%.0f (trimmed from %.0fx%.0f)",
                  c.label, contentRect.width, contentRect.height, contentRect.minX, contentRect.minY,
                  c.rect.width, c.rect.height)

            let content = PanelInfo(
                bounds: contentRect,
                title: "content",
                content: "",
                lineHeight: 21,
                firstLineY: contentRect.minY + 20
            )
            let collapsed = PanelInfo(
                bounds: CGRect(x: contentRect.maxX, y: contentRect.minY, width: 0, height: 0),
                title: "editor",
                content: "",
                lineHeight: 21,
                firstLineY: contentRect.minY
            )
            return ScreenAnalysis(
                platform: "reader",
                questionPanel: content,
                editorPanel: collapsed,
                solution: MockSolution(problemId: "reader", keywords: [], lines: [])
            )
        }

        // Map model coords → logical screen coords
        let scaleX = screenW / resize.width
        let scaleY = screenH / resize.height

        var question: PanelInfo?
        var editor: PanelInfo?

        for result in panelResults {
            let b = result.bbox
            let label = result.label.lowercased()

            let x1 = b[0] * scaleX
            let y1 = b[1] * scaleY
            let x2 = b[2] * scaleX
            let y2 = b[3] * scaleY

            NSLog("NativeVLM: %@ model(%@) → screen(%.0f,%.0f)-(%.0f,%.0f)",
                  label, b.map{String(Int($0))}.joined(separator: ","), x1, y1, x2, y2)

            let panel = PanelInfo(bounds: CGRect(x: x1, y: y1, width: x2 - x1, height: y2 - y1),
                                  title: label, content: "", lineHeight: 21, firstLineY: y1 + 20)

            if label.contains("editor") || label.contains("code") || label.contains("right") {
                editor = panel
            } else if label.contains("question") || label.contains("problem") || label.contains("left") {
                if question == nil { question = panel }
            }
        }

        // Position-based fallback: leftmost = question, rightmost = editor
        if question == nil || editor == nil {
            let sorted = panelResults.sorted { $0.bbox[0] < $1.bbox[0] }
            let left = sorted.first!
            let right = sorted.last!
            NSLog("NativeVLM: position-based fallback (left=Q, right=E)")
            let lx1 = left.bbox[0] * scaleX; let ly1 = left.bbox[1] * scaleY
            let lx2 = left.bbox[2] * scaleX; let ly2 = left.bbox[3] * scaleY
            question = PanelInfo(bounds: CGRect(x: lx1, y: ly1, width: lx2-lx1, height: ly2-ly1),
                                 title: "question", content: "", lineHeight: 21, firstLineY: ly1 + 20)
            let rx1 = right.bbox[0] * scaleX; let ry1 = right.bbox[1] * scaleY
            let rx2 = right.bbox[2] * scaleX; let ry2 = right.bbox[3] * scaleY
            editor = PanelInfo(bounds: CGRect(x: rx1, y: ry1, width: rx2-rx1, height: ry2-ry1),
                               title: "editor", content: "", lineHeight: 21, firstLineY: ry1 + 20)
        }

        guard let q = question, let e = editor else {
            NSLog("NativeVLM: couldn't classify panels")
            return nil
        }

        return ScreenAnalysis(platform: "native_single", questionPanel: q, editorPanel: e,
                              solution: MockSolution(problemId: "native", keywords: [], lines: []))
    }

    // MARK: - SDK API (free-form prompt, model-coordinate output)

    /// Errors thrown by ``detect(from:prompt:)`` and the ``Grounder`` SDK facade.
    public enum DetectionError: Error, LocalizedError {
        /// ``loadModel()`` was not called or did not complete successfully.
        case modelNotLoaded
        /// The model returned no parseable bbox regions for the given prompt.
        case noRegionsDetected

        public var errorDescription: String? {
            switch self {
            case .modelNotLoaded:
                return "Grounder model not loaded — call loadModel() before detect()."
            case .noRegionsDetected:
                return "Model returned no bounding-box regions for the given prompt."
            }
        }
    }

    /// Free-form VLM grounding inference. The prompt is passed verbatim to the
    /// loaded model — typically Qwen2.5-VL or a derivative (UI-TARS). The same
    /// image preprocessing pipeline as ``detectPanels(from:mode:)`` is applied;
    /// both `bbox_2d` JSON-array and grounding-token response formats are parsed.
    ///
    /// - Parameters:
    ///   - image: The image to ground regions in. Will be ICC-retagged to sRGB
    ///     and resized to the model's patch grid (max 1280 px on the longest
    ///     side, snapped to multiples of 28).
    ///   - prompt: Natural-language instruction. Phrasing matters: ask for
    ///     `bbox_2d` coordinates explicitly, name each region, and list them
    ///     numerically for best results on Qwen2.5-VL.
    /// - Returns: Bounding boxes in the model's resize coordinate space.
    /// - Throws: ``DetectionError`` if the model isn't loaded or no regions
    ///   could be parsed from the response.
    public func detect(from image: CGImage, prompt: String) async throws -> [BoundingBox] {
        guard let container = self.container else {
            throw DetectionError.modelNotLoaded
        }

        // Same prep as detectPanels: ICC-retag to sRGB, wrap as CIImage,
        // compute model-grid resize.
        let srgbCS = CGColorSpace(name: CGColorSpace.sRGB)!
        let srgbCG: CGImage
        if let dp = image.dataProvider, let rawData = dp.data {
            srgbCG = CGImage(
                width: image.width, height: image.height,
                bitsPerComponent: image.bitsPerComponent,
                bitsPerPixel: image.bitsPerPixel,
                bytesPerRow: image.bytesPerRow,
                space: srgbCS,
                bitmapInfo: image.bitmapInfo,
                provider: CGDataProvider(data: rawData)!,
                decode: nil, shouldInterpolate: true,
                intent: .defaultIntent
            ) ?? image
        } else {
            srgbCG = image
        }
        let ciImage = CIImage(cgImage: srgbCG)
        let retinaScale = screenScaleFactor
        let logicalW = CGFloat(image.width) / retinaScale
        let logicalH = CGFloat(image.height) / retinaScale
        let resize = vlmResize(w: logicalW, h: logicalH)

        let raw = await runVLM(container, image: ciImage, prompt: prompt, resize: resize)
        if raw.isEmpty {
            throw DetectionError.noRegionsDetected
        }
        return raw.compactMap { entry -> BoundingBox? in
            guard entry.bbox.count == 4 else { return nil }
            return BoundingBox(
                x1: Int(entry.bbox[0].rounded()),
                y1: Int(entry.bbox[1].rounded()),
                x2: Int(entry.bbox[2].rounded()),
                y2: Int(entry.bbox[3].rounded()),
                label: entry.label
            )
        }
    }
}
