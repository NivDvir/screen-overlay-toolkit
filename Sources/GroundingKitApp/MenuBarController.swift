import AppKit

/// Minimal menu bar presence for GroundingKit.
///
/// Shows the current engine status next to a target icon in the system
/// menu bar, with a dropdown menu exposing the most common user actions
/// (view log, reveal artifacts in Finder, quit). The engine keeps running
/// regardless — this is an observer + control surface, not the engine itself.
final class MenuBarController: NSObject {
    private let statusItem: NSStatusItem
    private let statusMenuItem: NSMenuItem
    private var latestDetail: String = "Starting..."

    override init() {
        self.statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        self.statusMenuItem = NSMenuItem(title: "Starting...", action: nil, keyEquivalent: "")
        super.init()
        configureButton()
        configureMenu()
    }

    /// Call with the latest status string from OverlayController.onStatusChanged.
    func update(status: String) {
        let trimmed = status.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        latestDetail = trimmed
        DispatchQueue.main.async { [weak self] in
            self?.statusItem.button?.title = " \(trimmed)"
            self?.statusMenuItem.title = trimmed
        }
    }

    private func configureButton() {
        guard let button = statusItem.button else { return }
        if let icon = NSImage(systemSymbolName: "target", accessibilityDescription: "GroundingKit") {
            icon.isTemplate = true
            button.image = icon
        }
        button.imagePosition = .imageLeft
        button.title = " GroundingKit"
    }

    private func configureMenu() {
        let menu = NSMenu()
        statusMenuItem.isEnabled = false
        menu.addItem(statusMenuItem)
        menu.addItem(.separator())
        menu.addItem(withTitle: "Open Log (/tmp/ccsv_overlay.log)",
                     action: #selector(openLog),
                     keyEquivalent: "l").target = self
        menu.addItem(withTitle: "Reveal Artifacts in Finder",
                     action: #selector(revealArtifacts),
                     keyEquivalent: "r").target = self
        menu.addItem(.separator())
        menu.addItem(withTitle: "Quit GroundingKit",
                     action: #selector(quit),
                     keyEquivalent: "q").target = self
        statusItem.menu = menu
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
