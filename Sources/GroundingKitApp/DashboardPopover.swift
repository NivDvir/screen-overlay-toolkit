import AppKit
import SwiftUI

/// Dashboard hosted in an NSPopover anchored to the menu bar status item.
///
/// Two design goals combined:
///   * **No persistent window** — the popover only exists when the user clicks
///     the menu bar icon, so nothing ever sits on top of the targeted browser.
///   * **Invisible to screen capture** — once shown, the popover's backing
///     NSWindow gets `sharingType = .none`, the same trick the overlay uses.
///     The VLM's `captureScreenExcluding` can't see the popover's pixels even
///     if the user keeps it open during a detection cycle, so OCR/grounding
///     is never corrupted by the GUI being open.
final class DashboardPopover: NSObject {
    private let popover = NSPopover()

    init(model: EngineModel) {
        super.init()
        let host = NSHostingController(rootView: DashboardView(model: model))
        popover.contentViewController = host
        popover.contentSize = NSSize(width: 820, height: 620)
        popover.behavior = .transient
        popover.animates = true
    }

    /// Toggle popover visibility, anchored to the menu bar status button.
    func toggle(relativeTo button: NSStatusBarButton) {
        if popover.isShown {
            popover.performClose(nil)
            return
        }
        NSApp.activate(ignoringOtherApps: true)
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        // Once the popover is visible, its internal window exists — hide it
        // from screen capture APIs so the VLM / OCR never sees it.
        popover.contentViewController?.view.window?.sharingType = .none
    }

    func close() { popover.performClose(nil) }
}
