import AppKit

/// Menu bar presence for GroundingKit.
///
/// Left-clicking the status item toggles a popover dashboard. The menu bar
/// icon itself shows the latest engine status string so users get glance-able
/// state without opening the popover. A right-click (or control-click) opens
/// a context menu with advanced actions; day-to-day controls live inside the
/// popover's footer bar instead.
final class MenuBarController: NSObject {
    private let statusItem: NSStatusItem
    private weak var popover: DashboardPopover?

    override init() {
        self.statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        super.init()
        configureButton()
    }

    func bind(popover: DashboardPopover) {
        self.popover = popover
    }

    /// Called whenever engine status changes. Displayed next to the icon.
    func update(status: String) {
        let trimmed = status.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        DispatchQueue.main.async { [weak self] in
            self?.statusItem.button?.title = " \(trimmed)"
        }
    }

    private func configureButton() {
        guard let button = statusItem.button else { return }
        if let icon = NSImage(systemSymbolName: "scope", accessibilityDescription: "GroundingKit") {
            icon.isTemplate = true
            button.image = icon
        }
        button.imagePosition = .imageLeft
        button.title = " GroundingKit"
        button.target = self
        button.action = #selector(handleClick(_:))
        button.sendAction(on: [.leftMouseUp, .rightMouseUp])
    }

    @objc private func handleClick(_ sender: Any?) {
        let event = NSApp.currentEvent
        if event?.type == .rightMouseUp || (event?.modifierFlags.contains(.control) ?? false) {
            showContextMenu()
        } else {
            popover?.toggle(relativeTo: statusItem.button!)
        }
    }

    private func showContextMenu() {
        let menu = NSMenu()
        menu.addItem(withTitle: "Open Log", action: #selector(openLog), keyEquivalent: "l").target = self
        menu.addItem(withTitle: "Reveal Artifacts in Finder", action: #selector(revealArtifacts), keyEquivalent: "r").target = self
        menu.addItem(.separator())
        menu.addItem(withTitle: "Quit GroundingKit", action: #selector(quit), keyEquivalent: "q").target = self
        // Attaching menu then popUpMenu lets it dismiss after selection.
        statusItem.menu = menu
        statusItem.button?.performClick(nil)
        statusItem.menu = nil  // detach so next left-click goes back to popover
    }

    @objc private func openLog() {
        let url = URL(fileURLWithPath: "/tmp/ccsv_overlay.log")
        if FileManager.default.fileExists(atPath: url.path) {
            NSWorkspace.shared.open(url)
        } else {
            NSSound.beep()
        }
    }

    @objc private func revealArtifacts() {
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

    @objc private func quit() {
        NSApp.terminate(nil)
    }
}
