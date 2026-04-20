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

    public func loadModel() async throws {
        guard container == nil else { return }

        let basePath = NSString(string: "~/.cache/huggingface/hub/models--mlx-community--Qwen2.5-VL-7B-Instruct-4bit/snapshots").expandingTildeInPath
        let fm = FileManager.default
        guard let snapshots = try? fm.contentsOfDirectory(atPath: basePath),
              let snapshot = snapshots.first(where: { !$0.hasPrefix(".") }) else {
            throw NSError(domain: "NativeVLM", code: 1, userInfo: [NSLocalizedDescriptionKey: "Model not found"])
        }
        modelPath = "\(basePath)/\(snapshot)"

        NSLog("NativeVLM: loading from %@", modelPath)
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
        let session = ChatSession(
            container,
            generateParameters: .init(maxTokens: 200, temperature: 0.0),
            processing: .init(resize: resize)
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

        // Mode-specific prompt — two-panel test-taking vs single-panel reading
        let prompt: String
        let requiredPanels: Int
        switch mode {
        case .twoPanel:
            prompt = "Detect these two UI panels and output their bbox_2d coordinates as a JSON array:\n1. \"question\" - the problem description panel on the left\n2. \"editor\" - the code editor panel on the right"
            requiredPanels = 2
        case .reader:
            prompt = """
            Locate the main reading column on this webpage — the single vertical column of prose that a "reader mode" browser extension would keep while stripping the rest. Return it as one bounding box.

            INCLUDE, from top to bottom: the article's H1 title at the top of the column, any byline / date / "From Wikipedia, the free encyclopedia"-style metadata line immediately below the title, and every body paragraph with its in-flow sub-headings ("History", "Abstract", "Methods") down to the last paragraph visible in the screenshot.

            DO NOT extend the box into neighbouring panels. A sidebar is any visually distinct box with stacked links, buttons, or settings (not prose). Examples of sidebars to EXCLUDE: Wikipedia "Contents" / "Tools" / "Appearance" / "Languages"; arXiv "Access Paper" / "References & Citations" / "Bookmark" / "Current browse context"; top site nav (search box, login). Also exclude browser chrome (tabs, address bar) and any bottom tab strip or footer.

            Output exactly one object as a JSON array:
            [{"label": "content", "bbox_2d": [x1, y1, x2, y2]}]
            """
            requiredPanels = 1
        }

        let panelResults = await runVLM(container, image: ciImage, prompt: prompt, resize: resize)

        let elapsed = (CFAbsoluteTimeGetCurrent() - start) * 1000
        NSLog("NativeVLM: inference %.0fms (mode=%@)", elapsed, String(describing: mode))

        guard panelResults.count >= requiredPanels else {
            NSLog("NativeVLM: need %d panels, got %d (mode=%@)", requiredPanels, panelResults.count, String(describing: mode))
            return nil
        }

        // Reader mode: return a ScreenAnalysis with only the content panel set as "question".
        // Editor panel gets a collapsed zero-width sentinel so downstream code treats it
        // as single-panel (reader flow).
        if mode == .reader {
            let scaleX = screenW / resize.width
            let scaleY = screenH / resize.height
            let b = panelResults[0].bbox
            let x1 = b[0] * scaleX, y1 = b[1] * scaleY
            let x2 = b[2] * scaleX, y2 = b[3] * scaleY
            NSLog("NativeVLM[reader]: content → screen(%.0f,%.0f)-(%.0f,%.0f)", x1, y1, x2, y2)
            let content = PanelInfo(
                bounds: CGRect(x: x1, y: y1, width: x2 - x1, height: y2 - y1),
                title: "content",
                content: "",
                lineHeight: 21,
                firstLineY: y1 + 20
            )
            let collapsed = PanelInfo(
                bounds: CGRect(x: x2, y: y1, width: 0, height: 0),
                title: "editor",
                content: "",
                lineHeight: 21,
                firstLineY: y1
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
}
