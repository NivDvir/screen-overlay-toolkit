import AppKit

/// Dynamic screen scale factor — replaces all hardcoded `2.0`
let screenScaleFactor: CGFloat = NSScreen.main?.backingScaleFactor ?? 2.0
