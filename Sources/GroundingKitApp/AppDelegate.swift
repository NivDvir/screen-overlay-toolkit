import AppKit
import GroundingKit

class AppDelegate: NSObject, NSApplicationDelegate {
    private var captureManager: ScreenCapture?
    private var overlayController: OverlayController?
    private var timer: Timer?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSLog("GroundingKit starting...")

        overlayController = OverlayController()
        captureManager = ScreenCapture(overlayController: overlayController!)

        timer = Timer.scheduledTimer(
            timeInterval: 0.15,
            target: captureManager!,
            selector: #selector(ScreenCapture.tick),
            userInfo: nil,
            repeats: true
        )

        NSLog("Capture timer started")
    }

    func applicationWillTerminate(_ notification: Notification) {
        timer?.invalidate()
        overlayController?.close()
        NSLog("GroundingKit stopped.")
    }
}
