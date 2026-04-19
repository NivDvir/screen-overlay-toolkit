import Vision
import CoreGraphics
import AppKit

/// Test multiple VN detection approaches on the same image.
/// Compares: Saliency, Document Segmentation, Text Rectangles, Detect Rectangles

@available(macOS 14.0, *)
struct RectTest {

    static func runAll(image: CGImage) {
        let imgW = CGFloat(image.width)
        let imgH = CGFloat(image.height)
        let scale: CGFloat = 2.0
        let logicalW = imgW / scale
        let logicalH = imgH / scale

        NSLog("=== VN API Comparison: %dx%d (%.0fx%.0f logical) ===", image.width, image.height, logicalW, logicalH)

        // --- 1. Objectness Saliency ---
        do {
            let request = VNGenerateObjectnessBasedSaliencyImageRequest()
            let handler = VNImageRequestHandler(cgImage: image, options: [:])
            let start = CFAbsoluteTimeGetCurrent()
            try handler.perform([request])
            let ms = (CFAbsoluteTimeGetCurrent() - start) * 1000

            if let obs = request.results?.first as? VNSaliencyImageObservation,
               let objects = obs.salientObjects {
                NSLog("[SALIENCY] %d objects in %.0fms", objects.count, ms)
                for (i, obj) in objects.enumerated() {
                    let box = obj.boundingBox
                    let r = CGRect(x: box.origin.x * logicalW,
                                   y: (1.0 - box.origin.y - box.height) * logicalH,
                                   width: box.width * logicalW,
                                   height: box.height * logicalH)
                    NSLog("  S%d: (%.0f,%.0f) %.0fx%.0f conf=%.2f",
                          i, r.minX, r.minY, r.width, r.height, obj.confidence)
                }
                // Also log heat map size
                let heatMap = obs.pixelBuffer
                NSLog("  heatMap: %dx%d", CVPixelBufferGetWidth(heatMap), CVPixelBufferGetHeight(heatMap))
            } else {
                NSLog("[SALIENCY] 0 objects in %.0fms", ms)
            }
        } catch {
            NSLog("[SALIENCY] ERROR: %@", error.localizedDescription)
        }

        // --- 2. Attention Saliency (for comparison) ---
        do {
            let request = VNGenerateAttentionBasedSaliencyImageRequest()
            let handler = VNImageRequestHandler(cgImage: image, options: [:])
            let start = CFAbsoluteTimeGetCurrent()
            try handler.perform([request])
            let ms = (CFAbsoluteTimeGetCurrent() - start) * 1000

            if let obs = request.results?.first as? VNSaliencyImageObservation,
               let objects = obs.salientObjects {
                NSLog("[ATTENTION] %d objects in %.0fms", objects.count, ms)
                for (i, obj) in objects.enumerated() {
                    let box = obj.boundingBox
                    let r = CGRect(x: box.origin.x * logicalW,
                                   y: (1.0 - box.origin.y - box.height) * logicalH,
                                   width: box.width * logicalW,
                                   height: box.height * logicalH)
                    NSLog("  A%d: (%.0f,%.0f) %.0fx%.0f conf=%.2f",
                          i, r.minX, r.minY, r.width, r.height, obj.confidence)
                }
            } else {
                NSLog("[ATTENTION] 0 objects in %.0fms", ms)
            }
        } catch {
            NSLog("[ATTENTION] ERROR: %@", error.localizedDescription)
        }

        // --- 3. Document Segmentation ---
        do {
            let request = VNDetectDocumentSegmentationRequest()
            let handler = VNImageRequestHandler(cgImage: image, options: [:])
            let start = CFAbsoluteTimeGetCurrent()
            try handler.perform([request])
            let ms = (CFAbsoluteTimeGetCurrent() - start) * 1000

            if let results = request.results, !results.isEmpty {
                NSLog("[DOC_SEG] %d results in %.0fms", results.count, ms)
                for (i, obs) in results.enumerated() {
                    let box = obs.boundingBox
                    let r = CGRect(x: box.origin.x * logicalW,
                                   y: (1.0 - box.origin.y - box.height) * logicalH,
                                   width: box.width * logicalW,
                                   height: box.height * logicalH)
                    NSLog("  D%d: (%.0f,%.0f) %.0fx%.0f conf=%.2f",
                          i, r.minX, r.minY, r.width, r.height, obs.confidence)

                    // Check pixel mask
                    if let mask = obs.globalSegmentationMask {
                        let buf = mask.pixelBuffer
                        NSLog("  mask: %dx%d", CVPixelBufferGetWidth(buf), CVPixelBufferGetHeight(buf))
                    }
                }
            } else {
                NSLog("[DOC_SEG] 0 results in %.0fms", ms)
            }
        } catch {
            NSLog("[DOC_SEG] ERROR: %@", error.localizedDescription)
        }

        // --- 4. Text Rectangles ---
        do {
            let request = VNDetectTextRectanglesRequest()
            let handler = VNImageRequestHandler(cgImage: image, options: [:])
            let start = CFAbsoluteTimeGetCurrent()
            try handler.perform([request])
            let ms = (CFAbsoluteTimeGetCurrent() - start) * 1000

            let count = request.results?.count ?? 0
            NSLog("[TEXT_RECT] %d regions in %.0fms", count, ms)
        } catch {
            NSLog("[TEXT_RECT] ERROR: %@", error.localizedDescription)
        }

        // --- 5. Detect Rectangles ---
        do {
            let request = VNDetectRectanglesRequest()
            request.maximumObservations = 16
            request.minimumSize = 0.05
            request.minimumConfidence = 0.3
            request.quadratureTolerance = 15.0

            let handler = VNImageRequestHandler(cgImage: image, options: [:])
            let start = CFAbsoluteTimeGetCurrent()
            try handler.perform([request])
            let ms = (CFAbsoluteTimeGetCurrent() - start) * 1000

            let count = request.results?.count ?? 0
            NSLog("[DETECT_RECT] %d rectangles in %.0fms", count, ms)
            for (i, obs) in (request.results ?? []).enumerated() {
                let box = obs.boundingBox
                let r = CGRect(x: box.origin.x * logicalW,
                               y: (1.0 - box.origin.y - box.height) * logicalH,
                               width: box.width * logicalW,
                               height: box.height * logicalH)
                NSLog("  R%d: (%.0f,%.0f) %.0fx%.0f conf=%.2f",
                      i, r.minX, r.minY, r.width, r.height, obs.confidence)
            }
        } catch {
            NSLog("[DETECT_RECT] ERROR: %@", error.localizedDescription)
        }

        NSLog("=== Done ===")
    }
}
