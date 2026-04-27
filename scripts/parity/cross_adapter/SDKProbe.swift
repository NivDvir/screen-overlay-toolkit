// SDK probe — calls Grounder.ground() DIRECTLY (no adapter wrapper).
// Establishes the in-process reference output that MCP and Osaurus
// adapter probes must match exactly.
//
// Build via xcodebuild against the same SPM Package as the rest of the repo.
// Reads image path + prompt from argv. Emits ONLY the bbox JSON to stdout
// (everything else goes to stderr) for clean piping.
//
//   swift build -c release  # or xcodebuild — both work for this small target
//   ./SDKProbe IMAGE_PATH "PROMPT"

import Foundation
import CoreGraphics
import AppKit
import GroundingKit

@MainActor
func loadCGImage(_ path: String) -> CGImage? {
    guard let img = NSImage(contentsOfFile: path),
          let cg = img.cgImage(forProposedRect: nil, context: nil, hints: nil)
    else { return nil }
    return cg
}

func emit(_ regions: [BoundingBox]) {
    let dicts: [[String: Any]] = regions.map {
        ["label": $0.label, "x1": $0.x1, "y1": $0.y1, "x2": $0.x2, "y2": $0.y2]
    }
    let payload: [String: Any] = ["regions": dicts]
    let data = try! JSONSerialization.data(
        withJSONObject: payload,
        options: [.sortedKeys, .prettyPrinted]
    )
    print(String(data: data, encoding: .utf8)!)
}

@main
struct SDKProbe {
    static func main() async throws {
        let args = CommandLine.arguments
        guard args.count >= 3 else {
            FileHandle.standardError.write(
                "usage: SDKProbe IMAGE_PATH \"PROMPT\"\n".data(using: .utf8)!
            )
            exit(2)
        }
        let imagePath = args[1]
        let prompt = args[2]

        FileHandle.standardError.write(
            "SDKProbe: loading image \(imagePath)\n".data(using: .utf8)!
        )
        guard let cg = await loadCGImage(imagePath) else {
            FileHandle.standardError.write("SDKProbe: failed to load image\n".data(using: .utf8)!)
            exit(3)
        }

        FileHandle.standardError.write("SDKProbe: constructing Grounder\n".data(using: .utf8)!)
        let grounder = try await Grounder()

        FileHandle.standardError.write("SDKProbe: calling ground(...)\n".data(using: .utf8)!)
        let regions = try await grounder.ground(image: cg, prompt: prompt)

        FileHandle.standardError.write(
            "SDKProbe: got \(regions.count) regions\n".data(using: .utf8)!
        )
        emit(regions)
    }
}
