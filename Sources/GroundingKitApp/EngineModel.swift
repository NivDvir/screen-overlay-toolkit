import SwiftUI

/// Shared observable model that mirrors the running engine for the GUI.
///
/// The engine publishes into this from the existing `await MainActor.run { }`
/// blocks in `main.swift`; SwiftUI views subscribe. Nothing in the engine's
/// logic depends on it — if the dashboard window is never opened, these
/// writes are harmless.
@MainActor
final class EngineModel: ObservableObject {
    static let shared = EngineModel()

    // MARK: Lifecycle

    /// When false, the main scan Timer skips its body. Overlay stays mounted
    /// but is cleared so the UI is visually quiet. Toggled from the dashboard.
    @Published var isRunning: Bool = true

    // MARK: Platform

    @Published var platformName: String = "—"

    // MARK: VLM

    enum VLMState: Equatable {
        case loading
        case ready
        case inferring
        case error(String)
    }
    @Published var vlmState: VLMState = .loading

    // MARK: Panels

    @Published var questionBounds: CGRect = .zero
    @Published var editorBounds: CGRect = .zero
    var boundsLocked: Bool { questionBounds != .zero && editorBounds != .zero }

    // MARK: OCR content

    @Published var questionText: String = ""
    @Published var editorLineCount: Int = 0
    @Published var accumulatedLines: Int = 0
    @Published var accumulatedChars: Int = 0
    @Published var scrollDownNeeded: Bool = false

    // MARK: Solver

    enum SolverState: Equatable {
        case idle
        case waiting
        case ready(lineCount: Int, source: String)
    }
    @Published var solverState: SolverState = .idle
    @Published var solutionCode: String = ""

    // MARK: Cycle + status line

    @Published var round: Int = 0
    @Published var cycleInRound: Int = 0
    @Published var statusLine: String = "Starting..."
}
