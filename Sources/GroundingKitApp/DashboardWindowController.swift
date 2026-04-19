import AppKit
import SwiftUI

/// Hosts DashboardView in a titled, resizable NSWindow. Singleton lifetime —
/// closing the window hides it; reopening via the menu bar reveals it again.
final class DashboardWindowController: NSWindowController, NSWindowDelegate {
    init(model: EngineModel) {
        let hosting = NSHostingController(rootView: DashboardView(model: model))
        let window = NSWindow(contentViewController: hosting)
        window.title = "GroundingKit"
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
        window.titlebarAppearsTransparent = true
        window.isMovableByWindowBackground = true
        window.setContentSize(NSSize(width: 820, height: 620))
        window.center()
        window.isReleasedWhenClosed = false
        super.init(window: window)
        window.delegate = self
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }

    /// Show + bring to front. Uses .regular activation policy temporarily so
    /// the window accepts focus reliably even from an .accessory (menu bar) app.
    func present() {
        NSApp.activate(ignoringOtherApps: true)
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        sender.orderOut(nil)
        return false
    }
}
