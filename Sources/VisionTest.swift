import Vision
import CoreGraphics
import AppKit

struct VisionTest {
    @available(macOS 26.0, *)
    static func runAll(image: CGImage) {
        let imgSize = CGSize(width: image.width, height: image.height)
        NSLog("VisionTest: %dx%d", image.width, image.height)

        NSLog("\n=== RecognizeDocumentsRequest (WWDC25) ===")
        Task {
            do {
                let request = RecognizeDocumentsRequest()
                let handler = ImageRequestHandler(image)
                let observations = try await handler.perform(request)

                NSLog("  Observations: %d", observations.count)

                for (i, obs) in observations.enumerated() {
                    let doc = obs.document

                    // Paragraphs
                    let paragraphs = doc.paragraphs
                    NSLog("  Doc %d: %d paragraphs, %d tables, %d lists, %d barcodes",
                          i, paragraphs.count, doc.tables.count, doc.lists.count, doc.barcodes.count)

                    // Show each paragraph with bounds
                    for (pi, para) in paragraphs.enumerated() {
                        let txt = String(para.transcript.prefix(60))
                        let rect = para.boundingRegion.boundingBox.toImageCoordinates(imgSize, origin: .upperLeft)
                        NSLog("    P%d: (%.0f,%.0f) %.0fx%.0f \"%@\"",
                              pi, rect.origin.x/2, rect.origin.y/2,
                              rect.size.width/2, rect.size.height/2, txt)
                    }

                    // Tables
                    for (ti, table) in doc.tables.enumerated() {
                        let rect = table.boundingRegion.boundingBox.toImageCoordinates(imgSize, origin: .upperLeft)
                        NSLog("    T%d: (%.0f,%.0f) %.0fx%.0f rows=%d",
                              ti, rect.origin.x/2, rect.origin.y/2,
                              rect.size.width/2, rect.size.height/2, table.rows.count)
                    }

                    // Lists
                    for (li, list) in doc.lists.enumerated() {
                        let rect = list.boundingRegion.boundingBox.toImageCoordinates(imgSize, origin: .upperLeft)
                        NSLog("    Li%d: (%.0f,%.0f) %.0fx%.0f",
                              li, rect.origin.x/2, rect.origin.y/2,
                              rect.size.width/2, rect.size.height/2)
                    }

                    // Full text lines
                    let lines = doc.text.lines
                    NSLog("  Total lines: %d", lines.count)
                    for (li, line) in lines.prefix(10).enumerated() {
                        let txt = String(line.transcript.prefix(50))
                        let rect = line.boundingRegion.boundingBox.toImageCoordinates(imgSize, origin: .upperLeft)
                        NSLog("    L%d: (%.0f,%.0f) %.0fx%.0f \"%@\"",
                              li, rect.origin.x/2, rect.origin.y/2,
                              rect.size.width/2, rect.size.height/2, txt)
                    }
                    if lines.count > 10 {
                        NSLog("    ... +%d more lines", lines.count - 10)
                    }

                    // Full transcript preview
                    let preview = String(doc.text.transcript.prefix(200))
                    NSLog("  Transcript: %@", preview)
                }
            } catch {
                NSLog("  ERROR: %@", error.localizedDescription)
            }
        }

        RunLoop.main.run(until: Date().addingTimeInterval(10))
        NSLog("=== Done ===")
    }
}
