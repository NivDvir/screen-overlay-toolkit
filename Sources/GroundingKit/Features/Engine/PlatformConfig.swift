import Foundation
import CoreGraphics
import AppKit

/// Platform configuration — controls how GroundingKit adapts to different browser/site layouts.
/// The default `generic` config targets any Chrome window with no site-specific filters applied.
/// Downstream users can define additional configs for specific sites they want to target.

// MARK: - Layout mode

/// High-level layout the VLM is being pointed at.
/// Controls the question-type classifier, the solution-generator prompt, and overlay placement.
public enum LayoutMode: String {
    /// Two-panel test-taking layout: question on one side, editor on the other.
    /// This is the original LeetCode / HackerRank shape.
    case twoPanel

    /// Single-panel long-form reading layout: an article, a PDF, a documentation page.
    /// No editor. The solution-generator produces a summary, not an answer.
    case reader

    /// Auto-detect at runtime based on VLM output.
    /// If the editor panel is <15% of screen width, treat the layout as `.reader`.
    /// Otherwise, `.twoPanel`.
    case auto
}

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

    /// Layout hint. `.auto` (default) picks `twoPanel` or `reader` from VLM output at runtime.
    public var layoutMode: LayoutMode

    public init(coverQuestion: Bool, stepAdvancement: Bool, layoutMode: LayoutMode = .auto) {
        self.coverQuestion = coverQuestion
        self.stepAdvancement = stepAdvancement
        self.layoutMode = layoutMode
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
    /// Uses `layoutMode = .auto` which picks reader vs twoPanel from VLM output.
    public static let generic = PlatformConfig(
        name: "Generic",
        browserWindowKeywords: [],
        sidebarLabels: [],
        uiKeywords: [],
        editorThemeIsDark: false,
        templateClassPatterns: [],
        promptIOHint: "",
        overlayMode: OverlayModeConfig(coverQuestion: true, stepAdvancement: false, layoutMode: .auto)
    )

    /// Reader preset — long-form reading pages (Wikipedia, arXiv, documentation).
    /// Forces single-panel reader mode so the MCQ classifier and editor machinery are skipped.
    public static let reader = PlatformConfig(
        name: "Reader",
        browserWindowKeywords: [],
        sidebarLabels: ["Contents", "References", "External links", "See also", "Appearance", "Tools"],
        uiKeywords: [],
        editorThemeIsDark: false,
        templateClassPatterns: [],
        promptIOHint: "",
        overlayMode: OverlayModeConfig(coverQuestion: false, stepAdvancement: false, layoutMode: .reader)
    )

    // MARK: - Auto-Detection

    /// Returns the active platform configuration. Default is `.generic`.
    /// Extend this method with additional detection heuristics to target specific sites.
    ///
    /// Env var overrides (for demos / testing):
    ///   - `GK_READER=1` → force `.reader` preset regardless of site
    public static func detect() -> PlatformConfig {
        if ProcessInfo.processInfo.environment["GK_READER"] == "1" {
            return .reader
        }
        return .generic
    }
}
