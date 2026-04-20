import AppKit
import SwiftUI

/// A detected text block from Vision OCR.
struct TextBlock: Identifiable {
    let id = UUID()
    let text: String
    let confidence: Float
    // Normalized coordinates (0-1), bottom-left origin (Vision format)
    let x: CGFloat
    let y: CGFloat
    let width: CGFloat
    let height: CGFloat
}

/// Manages the transparent overlay window and renders detection results.
/// No @MainActor — we call from main thread explicitly via DispatchQueue.main
public class OverlayController {
    private let window: NSWindow
    private let hostingView: NSHostingView<OverlayView>
    private let viewModel = OverlayViewModel()

    public var windowNumber: Int { window.windowNumber }

    public init() {
        guard let screen = NSScreen.main else {
            fatalError("No screen available")
        }

        // Create transparent, click-through, always-on-top window
        window = NSWindow(
            contentRect: screen.frame,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.level = .floating
        window.backgroundColor = .clear
        window.isOpaque = false
        window.hasShadow = false
        window.ignoresMouseEvents = true
        // For demo/blog asset capture the overlay must be visible to screen recording.
        // Override the ambient default (which may be .none on recent macOS) explicitly.
        window.sharingType = .readOnly
        window.collectionBehavior = [.canJoinAllSpaces, .stationary]

        // SwiftUI view for rendering
        hostingView = NSHostingView(rootView: OverlayView(viewModel: viewModel))
        window.contentView = hostingView

        window.orderFrontRegardless()
        NSLog("Overlay window created: \(Int(screen.frame.width))x\(Int(screen.frame.height))")

    }

    func updateTextBlocks(_ blocks: [TextBlock]) {
        viewModel.textBlocks = blocks
    }

    public func showPanel(_ panel: PanelRect, color: String, label: String) {
        viewModel.panels.append(OverlayViewModel.PanelDisplay(
            rect: panel, color: color, label: label
        ))
    }

    public func clear() {
        viewModel.panels = []
        viewModel.textBlocks = []
    }

    public func hide() {
        window.orderOut(nil)
    }

    public func show() {
        window.orderFrontRegardless()
    }

    public func close() {
        window.orderOut(nil)
    }

    public func showGhostClues(_ clues: [GhostClue]) {
        viewModel.ghostClues = clues
    }

    /// Called whenever status changes. Consumers (e.g. a menu bar UI) can observe.
    public var onStatusChanged: ((String) -> Void)?

    public func setStatus(_ text: String) {
        viewModel.statusText = text
        onStatusChanged?(text)
    }

    public func setStatusSegments(_ segments: [StatusSegment]) {
        viewModel.statusSegments = segments
        onStatusChanged?(segments.map { $0.text }.joined())
    }

    /// Export the overlay window content as a CGImage (ghost clues on dark background).
    /// Used by the HumanPlayer process to "see" the overlay signals.
    /// Uses NSView.cacheDisplay to capture the SwiftUI rendering — bypasses sharingType = .none.
    public func exportOverlayFrame() -> CGImage? {
        let bounds = hostingView.bounds
        guard bounds.width > 0 && bounds.height > 0 else { return nil }

        guard let bitmapRep = hostingView.bitmapImageRepForCachingDisplay(in: bounds) else { return nil }
        hostingView.cacheDisplay(in: bounds, to: bitmapRep)
        return bitmapRep.cgImage
    }

    /// Stage 1: Show red boxes around detected question text lines (collecting phase)
    public func showCollectingBoxes(_ boxes: [CGRect]) {
        viewModel.collectingBoxes = boxes
    }

    /// Stage 2: Set whether the question panel border should blink
    public func setQuestionPanelBlinking(_ blinking: Bool) {
        viewModel.questionPanelBlinking = blinking
    }

    /// Show the full solution code on top of the question panel as a reference sheet.
    /// Stays visible while the user types line-by-line on the editor side.
    public func showSolutionOnQuestion(code: String, questionBounds: CGRect) {
        viewModel.solutionCode = code
        viewModel.questionBounds = questionBounds
    }

    /// Reader-mode output — a floating summary card anchored next to the content panel.
    /// The card uses a translucent material so the underlying article stays readable behind it.
    /// Bullets are extracted from `•`-prefixed lines in `text`; other lines are dropped.
    /// Passing empty `text` just updates the anchor (enables the soft halo) without
    /// clearing an existing summary.
    public func showReaderSummary(_ text: String, nearPanel bounds: CGRect) {
        viewModel.summaryAnchor = bounds
        if !text.isEmpty {
            viewModel.summaryBullets = Self.parseBullets(from: text)
        }
    }

    public func clearReaderSummary() {
        viewModel.summaryBullets = []
        viewModel.summaryAnchor = .zero
    }

    private static func parseBullets(from text: String) -> [String] {
        let trimSet = CharacterSet(charactersIn: "•◦‣⁃-* \t")
        return text.components(separatedBy: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { line in
                line.hasPrefix("•") || line.hasPrefix("-") || line.hasPrefix("*")
            }
            .map { $0.trimmingCharacters(in: trimSet) }
            .filter { !$0.isEmpty }
    }
}

public struct StatusSegment {
    public let text: String
    public let color: String  // "white", "yellow", "green", "gray", "cyan"

    public init(text: String, color: String) {
        self.text = text
        self.color = color
    }
}

/// Observable view model — bridges detection results to SwiftUI.
class OverlayViewModel: ObservableObject {
    struct PanelDisplay {
        let rect: PanelRect
        let color: String
        let label: String
    }
    @Published var panels: [PanelDisplay] = []
    @Published var textBlocks: [TextBlock] = []
    @Published var ghostClues: [GhostClue] = []
    @Published var statusText: String = ""
    @Published var statusSegments: [StatusSegment] = []
    /// Full solution code to display on the question panel as a reference sheet
    @Published var solutionCode: String = ""
    /// Question panel bounds (for positioning the solution overlay)
    @Published var questionBounds: CGRect = .zero
    /// Stage 1: Red boxes around detected question text lines (collecting phase)
    @Published var collectingBoxes: [CGRect] = []
    /// Whether the question panel border should blink (Stage 2: waiting for Claude)
    @Published var questionPanelBlinking: Bool = false
    /// Reader-mode summary bullets (card floats next to content panel)
    @Published var summaryBullets: [String] = []
    /// Panel the summary card should anchor next to
    @Published var summaryAnchor: CGRect = .zero
    /// Brief flash text for corner triggers (reset, screenshot escalation)
    @Published var cornerFlash: String = ""
}

/// The SwiftUI overlay view — draws panel boxes and/or red text boxes.
struct OverlayView: View {
    @ObservedObject var viewModel: OverlayViewModel
    @State private var pulsePhase: Double = 0

    var body: some View {
        // Smooth loading pulse: opacity cycles between 0.3 and 1.0 over ~2.5s
        let _ = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { _ in
            DispatchQueue.main.async { pulsePhase += 0.05 }
        }
        GeometryReader { geometry in
            let screenW = geometry.size.width
            let screenH = geometry.size.height

            ZStack {
                Color.clear

                // Status bar — fixed-width pill, segmented colors, left-aligned
                if !viewModel.statusSegments.isEmpty {
                    HStack(spacing: 0) {
                        ForEach(Array(viewModel.statusSegments.enumerated()), id: \.offset) { _, seg in
                            Text(seg.text)
                                .font(.system(size: 11, weight: .medium, design: .monospaced))
                                .foregroundColor(segColor(seg.color))
                        }
                        Spacer()
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 4)
                    .frame(width: 380, alignment: .leading)
                    .background(Color.black.opacity(0.75))
                    .cornerRadius(6)
                    .position(x: 196, y: screenH - 20)
                } else if !viewModel.statusText.isEmpty {
                    // Fallback plain text
                    HStack {
                        Text(viewModel.statusText)
                            .font(.system(size: 11, weight: .medium, design: .monospaced))
                            .foregroundColor(.white)
                            .lineLimit(1)
                        Spacer()
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 4)
                    .frame(width: 380, alignment: .leading)
                    .background(Color.black.opacity(0.75))
                    .cornerRadius(6)
                    .position(x: 196, y: screenH - 20)
                }

                // Panel boxes (each independently detected)
                ForEach(Array(viewModel.panels.enumerated()), id: \.offset) { _, p in
                    let isQuestion = p.label == "QUESTION"
                    let shouldPulse = isQuestion && viewModel.questionPanelBlinking
                    let baseColor: Color = p.color == "blue" ? .blue : p.color == "green" ? .green : p.color == "yellow" ? .yellow : .red
                    // Gentle 1s breathing pulse: opacity fades 0.3 ↔ 1.0
                    let pulseOpacity = shouldPulse ? 0.3 + 0.7 * (0.5 + 0.5 * sin(pulsePhase * 6.28)) : 1.0
                    let panelColor = baseColor.opacity(pulseOpacity)
                    panelBox(p.rect, screenH: screenH, color: panelColor, label: p.label)
                }

                // Solution code reference — rendered on top of the question panel
                if !viewModel.solutionCode.isEmpty && viewModel.questionBounds != .zero {
                    let qb = viewModel.questionBounds
                    let codeLines = viewModel.solutionCode.components(separatedBy: "\n")
                    ScrollView(.vertical, showsIndicators: false) {
                        VStack(alignment: .leading, spacing: 1) {
                            ForEach(Array(codeLines.enumerated()), id: \.offset) { _, line in
                                let isSolution = line.hasPrefix("→ ")
                                let displayText = isSolution ? String(line.dropFirst(2)) : (line.hasPrefix("  ") ? String(line.dropFirst(2)) : line)
                                Text(displayText)
                                    .font(.system(size: 13, weight: isSolution ? .semibold : .regular, design: .monospaced))
                                    .foregroundColor(isSolution ? Color.green : Color.gray.opacity(0.7))
                                    .lineLimit(1)
                            }
                        }
                        .padding(10)
                    }
                    .frame(width: qb.width - 16, height: qb.height - 16)
                    .background(Color.black.opacity(0.92))
                    .cornerRadius(6)
                    .position(x: qb.midX, y: qb.midY)
                }

                // Reader-mode soft halo — a whisper of navy behind the detected content
                // that marks the region without imposing a hard rectangular frame.
                // Appears as soon as the content anchor is known (before the summary
                // arrives) so the visual grounding is live during the OCR / summarise
                // phase as well.
                if viewModel.summaryAnchor != .zero {
                    let anchor = viewModel.summaryAnchor

                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .fill(
                            RadialGradient(
                                colors: [
                                    Self.accentNavy.opacity(0.09),
                                    Self.accentNavy.opacity(0.035),
                                    Color.clear,
                                ],
                                center: .center,
                                startRadius: min(anchor.width, anchor.height) * 0.15,
                                endRadius: min(anchor.width, anchor.height) * 0.78
                            )
                        )
                        .frame(width: anchor.width + 32, height: anchor.height + 32)
                        .position(x: anchor.midX, y: anchor.midY)
                        .allowsHitTesting(false)

                    // Hairline outline — drop it to 8% opacity; closer to a whisper
                    // than a frame. Gone entirely at smaller resolutions.
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .strokeBorder(Self.accentNavy.opacity(0.10), lineWidth: 0.8)
                        .frame(width: anchor.width, height: anchor.height)
                        .position(x: anchor.midX, y: anchor.midY)
                        .allowsHitTesting(false)
                }

                // Summary card — shows only once bullets have actually arrived.
                if !viewModel.summaryBullets.isEmpty && viewModel.summaryAnchor != .zero {
                    let anchor = viewModel.summaryAnchor
                    let cardWidth: CGFloat = 360
                    let cardHSide: CGFloat = cardWidth / 2
                    let rightEdge = min(anchor.maxX - 18, screenW - 18)
                    let cardX = rightEdge - cardHSide
                    let cardY = anchor.minY + 230
                    summaryCard(bullets: viewModel.summaryBullets, width: cardWidth)
                        .position(x: cardX, y: cardY)
                        .transition(.asymmetric(
                            insertion: .move(edge: .trailing).combined(with: .opacity),
                            removal: .opacity
                        ))
                        .animation(.spring(response: 0.35, dampingFraction: 0.78), value: viewModel.summaryBullets.count)
                }

                // Ghost clues — solution lines rendered at editor positions
                ForEach(Array(viewModel.ghostClues.enumerated()), id: \.offset) { _, clue in
                    ghostClueLine(clue)
                }

                // Stage 1: Red boxes around detected question text (collecting phase)
                ForEach(Array(viewModel.collectingBoxes.enumerated()), id: \.offset) { _, rect in
                    Rectangle()
                        .stroke(Color.red.opacity(0.7), lineWidth: 1.5)
                        .background(Color.red.opacity(0.05))
                        .cornerRadius(2)
                        .frame(width: rect.width, height: rect.height)
                        .position(x: rect.midX, y: rect.midY)
                }

                // Red text boxes (code line tracking — legacy)
                let merged = mergeLines(viewModel.textBlocks, screenW: screenW, screenH: screenH)
                ForEach(Array(merged.enumerated()), id: \.offset) { _, rect in
                    Rectangle()
                        .stroke(Color.red.opacity(0.6), lineWidth: 1.5)
                        .background(Color.red.opacity(0.06))
                        .cornerRadius(2)
                        .frame(width: rect.width, height: rect.height)
                        .position(x: rect.midX, y: rect.midY)
                }

                // Corner trigger flash (reset / screenshot escalation)
                if !viewModel.cornerFlash.isEmpty {
                    Text(viewModel.cornerFlash)
                        .font(.system(size: 24, weight: .bold, design: .rounded))
                        .foregroundColor(.white)
                        .padding(.horizontal, 20)
                        .padding(.vertical, 12)
                        .background(Color.orange.opacity(0.9))
                        .cornerRadius(12)
                        .position(x: screenW / 2, y: 60)
                }
            } // ZStack
        } // GeometryReader
        .edgesIgnoringSafeArea(.all)
    } // body

    func segColor(_ name: String) -> Color {
        switch name {
        case "yellow": return .yellow
        case "green":  return .green
        case "cyan":   return Color(red: 0.3, green: 0.8, blue: 1.0)
        case "gray":   return Color(white: 0.5)
        case "red":    return .red
        default:       return .white
        }
    }

    /// Architectural palette (matches the AppIcon): deep navy + warm accent + slate.
    private static let accentNavy = Color(red: 29/255, green: 74/255, blue: 137/255)
    private static let accentWarm = Color(red: 240/255, green: 155/255, blue: 55/255)
    private static let inkPrimary = Color(red: 22/255, green: 28/255, blue: 40/255)
    private static let inkMuted   = Color(red: 80/255, green: 95/255, blue: 115/255)

    @ViewBuilder
    func summaryCard(bullets: [String], width: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: 11) {
            // Header row
            HStack(spacing: 8) {
                Image(systemName: "scope")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(Self.accentNavy)
                Text("Summary")
                    .font(.system(size: 13, weight: .semibold, design: .default))
                    .foregroundColor(Self.inkPrimary)
                Spacer(minLength: 8)
                Text("\(bullets.count) points")
                    .font(.system(size: 10, weight: .medium, design: .default))
                    .foregroundColor(Self.inkMuted)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 2)
                    .background(
                        Capsule().fill(Self.accentNavy.opacity(0.08))
                    )
            }

            // Hairline divider
            Rectangle()
                .fill(Self.accentNavy.opacity(0.14))
                .frame(height: 1)

            // Bullet list
            VStack(alignment: .leading, spacing: 9) {
                ForEach(Array(bullets.enumerated()), id: \.offset) { _, bullet in
                    HStack(alignment: .top, spacing: 9) {
                        Text("•")
                            .font(.system(size: 14, weight: .bold))
                            .foregroundColor(Self.accentWarm)
                            .frame(width: 10, alignment: .leading)
                        Text(bullet)
                            .font(.system(size: 12, weight: .regular, design: .default))
                            .foregroundColor(Self.inkPrimary)
                            .lineSpacing(2)
                            .fixedSize(horizontal: false, vertical: true)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }

            // Footer attribution
            HStack(spacing: 5) {
                Spacer(minLength: 0)
                Image(systemName: "sparkle")
                    .font(.system(size: 8))
                    .foregroundColor(Self.inkMuted.opacity(0.6))
                Text("grounded locally by GroundingKit")
                    .font(.system(size: 9, weight: .medium, design: .default))
                    .foregroundColor(Self.inkMuted.opacity(0.65))
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .frame(width: width, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color(red: 0.985, green: 0.988, blue: 0.995))  // near-white cool, matches icon palette
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(
                    LinearGradient(
                        colors: [Self.accentNavy.opacity(0.45), Self.accentNavy.opacity(0.20)],
                        startPoint: .topLeading, endPoint: .bottomTrailing
                    ),
                    lineWidth: 1.2
                )
        )
        .shadow(color: Self.accentNavy.opacity(0.25), radius: 18, x: 0, y: 8)
        .shadow(color: Color.black.opacity(0.10), radius: 4, x: 0, y: 2)
    }

    @ViewBuilder
    func panelBox(_ panel: PanelRect, screenH: CGFloat, color: Color, label: String) -> some View {
        let rect = CGRect(x: panel.x, y: panel.y, width: panel.width, height: panel.height)

        // Border — thick and bright for visibility
        Rectangle()
            .stroke(color, lineWidth: 3)
            .background(color.opacity(0.04))
            .cornerRadius(4)
            .frame(width: rect.width, height: rect.height)
            .position(x: rect.midX, y: rect.midY)

        // Label
        Text("  \(label)  ")
            .font(.system(size: 13, weight: .bold))
            .foregroundColor(.white)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(color.opacity(0.95))
            .cornerRadius(5)
            .position(x: rect.minX + 70, y: rect.minY + 15)
    }

    func ghostClueLine(_ clue: GhostClue) -> some View {
        let displayText = clue.text.count > 60 ? String(clue.text.prefix(57)) + "..." : clue.text

        return ZStack(alignment: .topLeading) {
            if clue.type == .progress {
                // Progress indicator
                Text(clue.text)
                    .font(.system(size: 10, weight: .medium, design: .monospaced))
                    .foregroundColor(Color.yellow.opacity(0.8))
                    .position(x: clue.x, y: clue.y)

            } else if clue.type == .scrollDown || clue.type == .scrollCaptured {
                // Scroll signal — arrow or checkmark at bottom of question panel
                let symbol = clue.type == .scrollDown ? "▼ scroll down ▼" : "✓ captured"
                let color = clue.type == .scrollDown ? Color.green : Color.green.opacity(0.6)
                Text(symbol)
                    .font(.system(size: 12, weight: .bold, design: .rounded))
                    .foregroundColor(color)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 4)
                    .background(Color.black.opacity(0.6))
                    .cornerRadius(8)
                    .position(x: clue.x, y: clue.y)

            } else if clue.type == .scrollRight || clue.type == .scrollRightCaptured {
                // Horizontal scroll signal — at right edge of sub-panel
                let symbol = clue.type == .scrollRight ? "\u{25B6} scroll right \u{25B6}" : "\u{2713} captured"
                let color = clue.type == .scrollRight ? Color.orange : Color.orange.opacity(0.6)
                Text(symbol)
                    .font(.system(size: 11, weight: .bold, design: .rounded))
                    .foregroundColor(color)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 3)
                    .background(Color.black.opacity(0.7))
                    .cornerRadius(6)
                    .position(x: clue.x, y: clue.y)

            } else if clue.type == .deleteMarker {
                // ═══ DELETE: solid strikethrough line + red X box ═══
                //
                //  ┌─┐
                //  │X│── /* Enter your code here... */ ──────────
                //  └─┘

                let lineLeft = clue.x
                let lineRight = clue.dashEndX + 20

                // Solid strikethrough across the entire text row
                DashedLine()
                    .stroke(Color.red.opacity(0.65), lineWidth: 2)
                    .frame(width: lineRight - lineLeft, height: 1)
                    .position(x: (lineLeft + lineRight) / 2, y: clue.dashY)

                // Red X in a small box at the left edge
                Text("X")
                    .font(.system(size: 10, weight: .bold, design: .monospaced))
                    .foregroundColor(.red.opacity(0.9))
                    .frame(width: 16, height: 16)
                    .overlay(Rectangle().stroke(Color.red.opacity(0.7), lineWidth: 1.5))
                    .position(x: lineLeft - 14, y: clue.dashY)

            } else if clue.type == .typedConfirm {
                // ═══ TYPED CONFIRMATION: brief green checkmark flash ═══
                Text("✓")
                    .font(.system(size: 16, weight: .bold))
                    .foregroundColor(.green)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Color.black.opacity(0.6))
                    .cornerRadius(4)
                    .position(x: clue.x, y: clue.y)

            } else if clue.type == .actionLabel {
                // ═══ ACTION LABEL: "STEP N/M — type next line:" ═══
                Text(clue.text)
                    .font(.system(size: 10, weight: .bold, design: .monospaced))
                    .foregroundColor(Color.green.opacity(0.9))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(Color.black.opacity(0.65))
                    .cornerRadius(5)
                    .position(x: clue.x, y: clue.y)

            } else if clue.type == .mcqAnswer {
                // ═══ MCQ: Green arrow pointing at correct answer ═══
                Text("➜")
                    .font(.system(size: 22, weight: .bold))
                    .foregroundColor(Color.green.opacity(0.9))
                    .shadow(color: .black.opacity(0.5), radius: 2, x: 1, y: 1)
                    .position(x: clue.x, y: clue.y)

            } else if clue.type == .mcqLabel {
                // ═══ MCQ: "Answer: B" label on question panel ═══
                Text(clue.text)
                    .font(.system(size: 14, weight: .bold, design: .rounded))
                    .foregroundColor(Color.green)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 6)
                    .background(Color.black.opacity(0.75))
                    .cornerRadius(8)
                    .position(x: clue.x, y: clue.y)

            } else if clue.type == .insertMarker {
                // ═══ INSERT: dashed line between rows → box with text ═══
                //
                //  public static void main(String[] args) {
                //  ············································ ┌·························┐
                //                                               · System.out.println(... ·
                //  ············································ └·························┘
                //  }

                let color = Color.green.opacity(0.75)

                // Horizontal dashed line across the code area at insertion Y
                let lineLeft = clue.dashEndX
                let lineRight = clue.x

                DashedLine()
                    .stroke(color, style: StrokeStyle(lineWidth: 1.5, dash: [3, 3]))
                    .frame(width: max(10, lineRight - lineLeft), height: 1)
                    .position(x: (lineLeft + lineRight) / 2, y: clue.dashY)

                // Vertical connector if box is at different Y than dashed line
                if abs(clue.y - clue.dashY) > 3 {
                    let vLineLen = abs(clue.y - clue.dashY)
                    let vLineMidY = (clue.y + clue.dashY) / 2
                    Rectangle()
                        .fill(color)
                        .frame(width: 1.5, height: vLineLen)
                        .position(x: clue.x, y: vLineMidY)
                }

                // Ghost text box — large bold white on black for OCR readability
                Text(" " + displayText + " ")
                    .font(.system(size: 15, weight: .bold, design: .monospaced))
                    .foregroundColor(Color.white)
                    .lineLimit(1)
                    .fixedSize()
                    .padding(.horizontal, 6)
                    .padding(.vertical, 4)
                    .background(Color.black.opacity(0.9))
                    .cornerRadius(4)
                    .position(x: clue.x + 80, y: clue.y)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private func ghostStyle(for type: GhostType) -> (color: Color, opacity: Double, fontWeight: Font.Weight, fontSize: CGFloat) {
        switch type {
        case .deleteMarker: return (.red, 0.7, .bold, 11)
        case .insertMarker: return (.green, 0.8, .medium, 11)
        case .typedConfirm: return (.green, 0.9, .bold, 16)
        case .actionLabel:  return (.green, 0.9, .bold, 10)
        case .nextAction:   return (.green, 0.85, .bold, 13)
        case .codeKey:      return (.green, 0.6, .medium, 13)
        case .codeCtx:      return (Color(red: 0.4, green: 0.7, blue: 1.0), 0.5, .regular, 13)
        case .codeBoiler:   return (.gray, 0.35, .light, 12)
        case .progress:       return (Color(red: 1.0, green: 0.8, blue: 0.3), 0.8, .bold, 11)
        case .scrollDown:     return (.green, 0.85, .bold, 14)
        case .scrollCaptured: return (.green, 0.8, .medium, 12)
        case .scrollRight:         return (.orange, 0.85, .bold, 13)
        case .scrollRightCaptured: return (.orange, 0.8, .medium, 12)
        case .mcqAnswer:           return (.green, 0.9, .bold, 22)
        case .mcqLabel:            return (.green, 0.9, .bold, 14)
        }
    }

    /// Merge text blocks on the same line and align to uniform width.
    private func mergeLines(_ blocks: [TextBlock], screenW: CGFloat, screenH: CGFloat) -> [CGRect] {
        guard !blocks.isEmpty else { return [] }

        // Convert to screen rects
        var rects = blocks.map { block -> CGRect in
            let x = block.x * screenW
            let y = (1 - block.y - block.height) * screenH
            let w = block.width * screenW
            let h = block.height * screenH
            return CGRect(x: x, y: y, width: w, height: h)
        }

        // Sort by Y
        rects.sort { $0.minY < $1.minY }

        // Merge blocks on the same line (within 8px Y)
        var merged: [CGRect] = []
        for rect in rects {
            if let last = merged.last, abs(rect.midY - last.midY) < 8 {
                // Same line — expand
                let minX = min(last.minX, rect.minX)
                let maxX = max(last.maxX, rect.maxX)
                let minY = min(last.minY, rect.minY)
                let maxY = max(last.maxY, rect.maxY)
                merged[merged.count - 1] = CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
            } else {
                merged.append(rect)
            }
        }

        // Align all boxes to uniform left/right edges
        guard !merged.isEmpty else { return [] }
        let leftEdge = merged.map { $0.minX }.min()! - 4
        let rightEdge = merged.map { $0.maxX }.max()! + 4
        let uniformWidth = rightEdge - leftEdge

        // Detect consistent line height
        var lineHeight: CGFloat = 18
        if merged.count >= 2 {
            let ys = merged.map { $0.midY }
            var spacings: [CGFloat] = []
            for i in 1..<ys.count {
                let s = ys[i] - ys[i-1]
                if s > 5 && s < 40 { spacings.append(s) }
            }
            if !spacings.isEmpty {
                lineHeight = spacings.sorted()[spacings.count / 2]  // median
            }
        }

        return merged.map { rect in
            CGRect(x: leftEdge, y: rect.midY - lineHeight/2, width: uniformWidth, height: lineHeight - 1)
        }
    }
}

/// Horizontal dashed line shape
struct DashedLine: Shape {
    func path(in rect: CGRect) -> Path {
        Path { p in
            p.move(to: CGPoint(x: rect.minX, y: rect.midY))
            p.addLine(to: CGPoint(x: rect.maxX, y: rect.midY))
        }
    }
}
