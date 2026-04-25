import Foundation
import CoreGraphics
import CoreImage
import AppKit
import MLXVLM
import MLXLMCommon
@preconcurrency import Tokenizers

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

func loadCIImage(from path: String) -> CIImage? {
    // Match GhostOverlay's production preprocessing: load CGImage, relabel as sRGB
    // (preserve raw bytes, strip ICC). Without this step, ImageIO converts Display-P3
    // PNGs to the working colorspace, producing different uint8 bytes than Python PIL
    // sees -- model then hallucinates bbox.
    guard let dataProvider = CGDataProvider(url: URL(fileURLWithPath: path) as CFURL),
          let cgImage = CGImage(pngDataProviderSource: dataProvider, decode: nil,
                                shouldInterpolate: false, intent: .defaultIntent) else {
        return nil
    }
    let srgbCS = CGColorSpace(name: CGColorSpace.sRGB)!
    let srgbCG: CGImage
    if let dp = cgImage.dataProvider, let rawData = dp.data {
        srgbCG = CGImage(
            width: cgImage.width, height: cgImage.height,
            bitsPerComponent: cgImage.bitsPerComponent,
            bitsPerPixel: cgImage.bitsPerPixel,
            bytesPerRow: cgImage.bytesPerRow,
            space: srgbCS,
            bitmapInfo: cgImage.bitmapInfo,
            provider: CGDataProvider(data: rawData)!,
            decode: nil, shouldInterpolate: true,
            intent: .defaultIntent
        ) ?? cgImage
    } else {
        srgbCG = cgImage
    }
    return CIImage(cgImage: srgbCG)
}

@main
struct App {
    static func main() async throws {
        let basePath = NSString(string: "~/.cache/huggingface/hub/models--mlx-community--Qwen2.5-VL-7B-Instruct-4bit/snapshots").expandingTildeInPath
        let fm = FileManager.default
        guard let snapshots = try? fm.contentsOfDirectory(atPath: basePath),
              let snapshot = snapshots.first(where: { !$0.hasPrefix(".") }) else {
            print("Model not found at \(basePath)")
            exit(1)
        }
        let modelPath = "\(basePath)/\(snapshot)"
        FileHandle.standardError.write("Loading model from \(modelPath)\n".data(using: .utf8)!)

        let container = try await loadModelContainer(from: URL(fileURLWithPath: modelPath), using: LocalTokenizerLoader())

        let imgPath = ProcessInfo.processInfo.environment["TEST_IMAGE"] ?? "/tmp/native_vlm_input.png"
        guard let ci = loadCIImage(from: imgPath) else {
            print("Image load failed: \(imgPath)")
            exit(2)
        }
        let resizeW = Int(ProcessInfo.processInfo.environment["RESIZE_W"] ?? "1260") ?? 1260
        let resizeH = Int(ProcessInfo.processInfo.environment["RESIZE_H"] ?? "812") ?? 812
        FileHandle.standardError.write("IMG: \(imgPath) resize=\(resizeW)x\(resizeH)\n".data(using: .utf8)!)

        if let dumpPath = ProcessInfo.processInfo.environment["DUMP_LANCZOS"] {
            let mean: (CGFloat, CGFloat, CGFloat) = (0.48145466, 0.4578275, 0.40821073)
            let std:  (CGFloat, CGFloat, CGFloat) = (0.26862954, 0.26130258, 0.27577711)
            let arr = MediaProcessing.resamplePILLanczosToArray(
                ci, to: CGSize(width: resizeW, height: resizeH), mean: mean, std: std)
            let floats = arr.asArray(Float.self)
            let n = resizeW * resizeH
            var rgb = [UInt8](repeating: 0, count: 3 * n)
            let mr = Float(mean.0), mg = Float(mean.1), mb = Float(mean.2)
            let sr = Float(std.0),  sg = Float(std.1),  sb = Float(std.2)
            for i in 0 ..< n {
                let r = floats[i] * sr + mr
                let g = floats[i + n] * sg + mg
                let b = floats[i + 2*n] * sb + mb
                rgb[i*3 + 0] = UInt8(max(0, min(255, (r * 255).rounded())))
                rgb[i*3 + 1] = UInt8(max(0, min(255, (g * 255).rounded())))
                rgb[i*3 + 2] = UInt8(max(0, min(255, (b * 255).rounded())))
            }
            try! Data(rgb).write(to: URL(fileURLWithPath: dumpPath))
            FileHandle.standardError.write("Dumped \(rgb.count) bytes to \(dumpPath)\n".data(using:.utf8)!)
            exit(0)
        }

        let promptVariant = ProcessInfo.processInfo.environment["PROMPT_VARIANT"] ?? "newlines"
        let prompt: String
        switch promptVariant {
        case "oneline":
            prompt = "Detect these two UI panels and output their bbox_2d coordinates as a JSON array: 1. 'question' - the problem description panel on the left 2. 'editor' - the code editor panel on the right"
        case "simple":
            prompt = "Output a JSON array of bbox_2d for the question panel (left) and editor panel (right)."
        default:
            prompt = "Detect these two UI panels and output their bbox_2d coordinates as a JSON array:\n1. \"question\" - the problem description panel on the left\n2. \"editor\" - the code editor panel on the right"
        }
        FileHandle.standardError.write("PROMPT: \(prompt)\n".data(using: .utf8)!)

        let session = ChatSession(
            container,
            generateParameters: .init(maxTokens: 200, temperature: 0.0),
            processing: .init(resize: CGSize(width: 1260, height: 812))
        )

        var response = ""
        for try await chunk in session.streamResponse(
            to: prompt, images: [.ciImage(ci)], videos: []
        ) {
            response += chunk
        }
        print("RAW_RESPONSE: \(response)")
    }
}
