import CoreGraphics
import AppKit

/// Platform configuration — controls how GroundingKit adapts to different browser/site layouts.
/// The default `generic` config targets any Chrome window with no site-specific filters applied.
/// Downstream users can define additional configs for specific sites they want to target.

// MARK: - Overlay Mode Configuration

/// Two independent overlay systems. Both can be enabled/disabled independently.
struct OverlayModeConfig {
    /// Cover Question: display the full solution overlaid on the question panel.
    /// The user reads the complete answer and types it from memory.
    var coverQuestion: Bool

    /// Step Advancement: display clue markers around the editor surface
    /// (insert markers, delete markers, step labels, progress).
    /// Guides the user to type the answer step by step, one editing action at a time.
    var stepAdvancement: Bool
}

struct PlatformConfig {
    let name: String
    let browserWindowKeywords: [String]
    let sidebarLabels: [String]        // OCR text to filter from question panel (DeepScan)
    let uiKeywords: [String]           // editor UI chrome to ignore (GhostLayout)
    let editorThemeIsDark: Bool        // controls image inversion for OCR
    let templateClassPatterns: [String] // for fold detection (ContentState)
    let promptIOHint: String           // solution generator prompt rule about I/O pattern
    var overlayMode: OverlayModeConfig // which overlay systems are active

    // MARK: - Generic

    /// Default platform — targets any Chrome window with no site-specific filters.
    static let generic = PlatformConfig(
        name: "Generic",
        browserWindowKeywords: [],
        sidebarLabels: [],
        uiKeywords: [],
        editorThemeIsDark: false,
        templateClassPatterns: [],
        promptIOHint: "",
        overlayMode: OverlayModeConfig(coverQuestion: true, stepAdvancement: false)
    )

    // MARK: - Auto-Detection

    /// Returns the active platform configuration. Default is `.generic`.
    /// Extend this method with additional detection heuristics to target specific sites.
    static func detect() -> PlatformConfig {
        return .generic
    }
}
