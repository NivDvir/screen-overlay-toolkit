import CoreGraphics
import AppKit

/// Find and capture only the Chrome/browser window (excludes other app windows).
/// This prevents OCR from reading overlapping IntelliJ, System Preferences, etc.

struct ChromeCapture {

    /// Optional window title keywords — if set, Chrome window matching one of these is preferred.
    /// Default: empty (any frontmost Chrome window). Populate via PlatformConfig for site-specific targeting.
    static var windowKeywords: [String] = []

    /// Find the Chrome window matching platform keywords
    static func findChromeWindowID() -> CGWindowID? {
        guard let windows = CGWindowListCopyWindowInfo(.optionOnScreenOnly, kCGNullWindowID) as? [[String: Any]] else {
            return nil
        }
        for w in windows {
            let owner = w[kCGWindowOwnerName as String] as? String ?? ""
            let name = w[kCGWindowName as String] as? String ?? ""
            let wid = w[kCGWindowNumber as String] as? Int ?? 0

            if owner.contains("Chrome") || owner.contains("Chromium") {
                if windowKeywords.contains(where: { name.localizedCaseInsensitiveContains($0) }) {
                    return CGWindowID(wid)
                }
            }
        }
        // Fallback: any Chrome window
        for w in windows {
            let owner = w[kCGWindowOwnerName as String] as? String ?? ""
            let wid = w[kCGWindowNumber as String] as? Int ?? 0
            if owner.contains("Chrome") || owner.contains("Chromium") {
                let layer = w[kCGWindowLayer as String] as? Int ?? -1
                if layer == 0 { return CGWindowID(wid) }
            }
        }
        return nil
    }

    /// Get Chrome window bounds (logical coordinates) via CGWindowList.
    /// Returns the window frame or .zero if Chrome not found.
    static func chromeBounds() -> CGRect {
        guard let windows = CGWindowListCopyWindowInfo(.optionOnScreenOnly, kCGNullWindowID) as? [[String: Any]] else {
            return .zero
        }
        for w in windows {
            let owner = w[kCGWindowOwnerName as String] as? String ?? ""
            let layer = w[kCGWindowLayer as String] as? Int ?? -1
            if (owner.contains("Chrome") || owner.contains("Chromium")) && layer == 0 {
                if let bounds = w[kCGWindowBounds as String] as? [String: CGFloat] {
                    return CGRect(x: bounds["X"] ?? 0, y: bounds["Y"] ?? 0,
                                  width: bounds["Width"] ?? 0, height: bounds["Height"] ?? 0)
                }
            }
        }
        return .zero
    }

    /// Clamp a rect to Chrome window bounds. Prevents VLM bounds from
    /// extending beyond Chrome into desktop/Finder content.
    static func clampToChrome(_ rect: CGRect) -> CGRect {
        let chrome = chromeBounds()
        guard chrome != .zero else { return rect }
        return rect.intersection(chrome)
    }

    /// Capture ONLY the Chrome window (single window, not composited)
    static func captureChrome() -> CGImage? {
        guard let wid = findChromeWindowID() else {
            NSLog("ChromeCapture: Chrome window not found, falling back to full screen")
            return CGWindowListCreateImage(CGRect.infinite, .optionOnScreenOnly, kCGNullWindowID, [.bestResolution])
        }
        // Capture this specific window only (no other windows composited)
        return CGWindowListCreateImage(.null, .optionIncludingWindow, wid, [.bestResolution, .boundsIgnoreFraming])
    }
}
