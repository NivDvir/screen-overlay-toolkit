import CoreGraphics
import AppKit

/// Platform configuration — controls how GroundingKit adapts to different browser/site layouts.
/// The default `generic` config targets any Chrome window with no site-specific filters applied.
/// Downstream users can define additional configs for specific sites they want to target.

// MARK: - Overlay Mode Configuration

/// Two independent overlay systems. Both can be enabled/disabled independently.
public struct OverlayModeConfig {
    /// Cover Question: display the full solution overlaid on the question panel.
    /// The user reads the complete answer and types it from memory.
    public var coverQuestion: Bool

    /// Step Advancement: display clue markers around the editor surface
    /// (insert markers, delete markers, step labels, progress).
    /// Guides the user to type the answer step by step, one editing action at a time.
    public var stepAdvancement: Bool

    public init(coverQuestion: Bool, stepAdvancement: Bool) {
        self.coverQuestion = coverQuestion
        self.stepAdvancement = stepAdvancement
    }
}

public struct PlatformConfig {
    public let name: String
    public let browserWindowKeywords: [String]
    public let sidebarLabels: [String]        // OCR text to filter from question panel (DeepScan)
    public let uiKeywords: [String]           // editor UI chrome to ignore (GhostLayout)
    public let editorThemeIsDark: Bool        // controls image inversion for OCR
    public let templateClassPatterns: [String] // for fold detection (ContentState)
    public let promptIOHint: String           // solution generator prompt rule about I/O pattern
    public var overlayMode: OverlayModeConfig // which overlay systems are active

    public init(name: String, browserWindowKeywords: [String], sidebarLabels: [String],
                uiKeywords: [String], editorThemeIsDark: Bool, templateClassPatterns: [String],
                promptIOHint: String, overlayMode: OverlayModeConfig) {
        self.name = name
        self.browserWindowKeywords = browserWindowKeywords
        self.sidebarLabels = sidebarLabels
        self.uiKeywords = uiKeywords
        self.editorThemeIsDark = editorThemeIsDark
        self.templateClassPatterns = templateClassPatterns
        self.promptIOHint = promptIOHint
        self.overlayMode = overlayMode
    }

    // MARK: - Generic

    /// Default platform — targets any Chrome window with no site-specific filters.
    public static let generic = PlatformConfig(
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
    public static func detect() -> PlatformConfig {
        return .generic
    }
}
