import SwiftUI

/// Main dashboard: a live read of the engine pipeline.
///
/// Reads from `EngineModel.shared`. Layout mirrors the physical pipeline —
/// status pills (VLM → Panels → Solver) at the top, Question OCR + Editor
/// OCR side-by-side (matching their on-screen positions), Solution below.
struct DashboardView: View {
    @ObservedObject var model: EngineModel

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().opacity(0.5)
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    pipelineCard
                    HStack(alignment: .top, spacing: 14) {
                        panelCard(
                            title: "Question",
                            accent: .blue,
                            bounds: model.questionBounds,
                            body: questionBody
                        )
                        panelCard(
                            title: "Editor",
                            accent: .green,
                            bounds: model.editorBounds,
                            body: editorBody
                        )
                    }
                    solutionCard
                }
                .padding(18)
            }
            Divider().opacity(0.5)
            footer
        }
        .frame(width: 820, height: 620)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    // MARK: Footer

    private var footer: some View {
        HStack(spacing: 12) {
            footerButton(label: "Open Log", systemImage: "doc.text") { openLog() }
            footerButton(label: "Reveal Artifacts", systemImage: "folder") { revealArtifacts() }
            Spacer()
            footerButton(label: "Quit", systemImage: "power") { NSApp.terminate(nil) }
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 10)
    }

    private func footerButton(label: String, systemImage: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(label, systemImage: systemImage)
                .font(.caption)
        }
        .buttonStyle(.borderless)
        .foregroundStyle(.secondary)
    }

    private func openLog() {
        let url = URL(fileURLWithPath: "/tmp/ccsv_overlay.log")
        if FileManager.default.fileExists(atPath: url.path) {
            NSWorkspace.shared.open(url)
        } else {
            NSSound.beep()
        }
    }

    private func revealArtifacts() {
        let candidates = [
            "/tmp/ccsv_overlay_frame.png",
            "/tmp/ccsv_solution_lines.txt",
            "/tmp/ccsv_accumulated_text.txt",
        ]
        if let first = candidates.first(where: { FileManager.default.fileExists(atPath: $0) }) {
            NSWorkspace.shared.selectFile(first, inFileViewerRootedAtPath: "/tmp")
        } else {
            NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: "/tmp")
        }
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: 12) {
            Image(systemName: "scope")
                .font(.system(size: 18, weight: .medium))
                .foregroundStyle(.tint)
            Text("GroundingKit")
                .font(.title3.weight(.semibold))

            platformPill

            Spacer()

            Button {
                model.isRunning.toggle()
            } label: {
                Label(model.isRunning ? "Stop" : "Start",
                      systemImage: model.isRunning ? "pause.fill" : "play.fill")
                    .labelStyle(.titleAndIcon)
                    .frame(minWidth: 54)
            }
            .buttonStyle(.bordered)
            .tint(model.isRunning ? .red : .green)
            .controlSize(.small)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 12)
    }

    private var platformPill: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(model.isRunning ? .green : .secondary)
                .frame(width: 7, height: 7)
            Text(model.platformName)
                .font(.caption.weight(.medium))
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 4)
        .background(Color(nsColor: .controlBackgroundColor), in: Capsule())
        .overlay(Capsule().stroke(Color(nsColor: .separatorColor).opacity(0.6), lineWidth: 0.5))
    }

    // MARK: Pipeline card (status pills + live status line)

    private var pipelineCard: some View {
        Card {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 18) {
                    stageIndicator(
                        label: "VLM",
                        state: vlmLabel,
                        color: vlmColor
                    )
                    arrow
                    stageIndicator(
                        label: "Panels",
                        state: model.boundsLocked ? "locked" : "detecting…",
                        color: model.boundsLocked ? .green : .orange
                    )
                    arrow
                    stageIndicator(
                        label: "Solver",
                        state: solverLabel,
                        color: solverColor
                    )
                    Spacer()
                    cycleBadge
                }
                Text(model.statusLine)
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
        }
    }

    private var arrow: some View {
        Image(systemName: "chevron.right")
            .font(.caption2.weight(.semibold))
            .foregroundStyle(.tertiary)
    }

    private var cycleBadge: some View {
        HStack(spacing: 5) {
            Text("R\(model.round)")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.primary)
            if model.cycleInRound > 0 {
                Text("· \(model.cycleInRound)/7")
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background(Color(nsColor: .controlBackgroundColor), in: Capsule())
    }

    private func stageIndicator(label: String, state: String, color: Color) -> some View {
        HStack(spacing: 7) {
            Circle()
                .fill(color)
                .frame(width: 8, height: 8)
                .overlay(Circle().stroke(color.opacity(0.3), lineWidth: 2).blur(radius: 1))
            VStack(alignment: .leading, spacing: 0) {
                Text(label)
                    .font(.system(.caption2, design: .default).weight(.semibold))
                    .foregroundStyle(.secondary)
                    .textCase(.uppercase)
                Text(state)
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.primary)
            }
        }
    }

    // MARK: Panel cards

    private func panelCard(
        title: String,
        accent: Color,
        bounds: CGRect,
        body: String
    ) -> some View {
        Card {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 8) {
                    Circle().fill(accent).frame(width: 8, height: 8)
                    Text(title)
                        .font(.system(.body, design: .default).weight(.semibold))
                    Spacer()
                    if bounds != .zero {
                        Text("\(Int(bounds.width))×\(Int(bounds.height))")
                            .font(.caption.monospaced())
                            .foregroundStyle(.secondary)
                    }
                }
                ScrollView {
                    Text(body.isEmpty ? "—" : body)
                        .font(.system(.callout, design: .monospaced))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .textSelection(.enabled)
                }
                .frame(height: 170)
            }
        }
        .frame(maxWidth: .infinity)
    }

    private var questionBody: String {
        var parts: [String] = []
        if model.accumulatedChars > 0 {
            let scrollMarker = model.scrollDownNeeded ? " ▼" : ""
            parts.append("[\(model.accumulatedLines) lines · \(model.accumulatedChars) chars\(scrollMarker)]")
        }
        if !model.questionText.isEmpty {
            parts.append(model.questionText)
        }
        return parts.joined(separator: "\n\n")
    }

    private var editorBody: String {
        "[\(model.editorLineCount) lines OCR'd]"
    }

    // MARK: Solution card

    private var solutionCard: some View {
        Card {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 8) {
                    Image(systemName: "wand.and.sparkles")
                        .font(.callout)
                        .foregroundStyle(.tint)
                    Text("Solution")
                        .font(.system(.body, design: .default).weight(.semibold))
                    Spacer()
                    if case .ready(let lines, let source) = model.solverState {
                        Text("\(lines) lines · \(source)")
                            .font(.caption.monospaced())
                            .foregroundStyle(.secondary)
                    } else if case .waiting = model.solverState {
                        ProgressView().controlSize(.mini)
                    }
                }
                ScrollView {
                    Text(model.solutionCode.isEmpty ? "— awaiting input —" : model.solutionCode)
                        .font(.system(.callout, design: .monospaced))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .textSelection(.enabled)
                }
                .frame(height: 200)
            }
        }
    }

    // MARK: State → label/color helpers

    private var vlmLabel: String {
        switch model.vlmState {
        case .loading: return "loading…"
        case .ready: return "ready"
        case .inferring: return "inferring…"
        case .error(let msg):
            return String(msg.prefix(24))
        }
    }
    private var vlmColor: Color {
        switch model.vlmState {
        case .loading: return .orange
        case .ready: return .green
        case .inferring: return .blue
        case .error: return .red
        }
    }
    private var solverLabel: String {
        switch model.solverState {
        case .idle: return "idle"
        case .waiting: return "asking…"
        case .ready: return "ready"
        }
    }
    private var solverColor: Color {
        switch model.solverState {
        case .idle: return .secondary
        case .waiting: return .orange
        case .ready: return .green
        }
    }
}

// MARK: - Card container

/// Minimal card wrapper: subtle filled background + hairline border + 12pt radius.
/// Uses system colors so it adapts to light/dark mode automatically.
struct Card<Content: View>: View {
    @ViewBuilder let content: () -> Content
    var body: some View {
        content()
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(Color(nsColor: .controlBackgroundColor))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .stroke(Color(nsColor: .separatorColor).opacity(0.5), lineWidth: 0.5)
            )
    }
}
