import AppKit
import QodeNotchCore

/// Notch measurements for a screen (real notch, or a simulated one on other displays).
struct NotchGeometry: Equatable {
    var screenFrame: CGRect
    var notchWidth: CGFloat
    var notchHeight: CGFloat
    var hasNotch: Bool

    /// Rect of the physical/simulated notch in screen coordinates.
    var notchRect: CGRect {
        CGRect(x: screenFrame.midX - notchWidth / 2, y: screenFrame.maxY - notchHeight, width: notchWidth, height: notchHeight)
    }
}

enum ScreenGeometry {
    static func hasNotch(_ screen: NSScreen) -> Bool {
        screen.auxiliaryTopLeftArea != nil && screen.safeAreaInsets.top > 0
    }

    static func geometry(for screen: NSScreen) -> NotchGeometry {
        if hasNotch(screen), let left = screen.auxiliaryTopLeftArea, let right = screen.auxiliaryTopRightArea {
            let width = screen.frame.width - left.width - right.width
            return NotchGeometry(screenFrame: screen.frame, notchWidth: max(width, 160), notchHeight: screen.safeAreaInsets.top, hasNotch: true)
        }
        // No notch: imitate one inside the menu bar.
        let menuBar = max(screen.frame.maxY - screen.visibleFrame.maxY, 24)
        let width = min(max(screen.frame.width * 0.11, 180), 220)
        return NotchGeometry(screenFrame: screen.frame, notchWidth: width, notchHeight: min(menuBar, 32), hasNotch: false)
    }

    static func displayKey(_ screen: NSScreen) -> String {
        screen.localizedName
    }

    /// Screen chosen by the user setting ("auto" prefers the built-in notch display).
    static func chosenScreen(setting: String, allowNonNotch: Bool) -> NSScreen? {
        let screens = NSScreen.screens
        if setting != "auto" && setting != "main", let match = screens.first(where: { displayKey($0) == setting }) {
            return match
        }
        if setting == "main" { return NSScreen.main ?? screens.first }
        if let notched = screens.first(where: hasNotch) { return notched }
        return allowNonNotch ? (NSScreen.main ?? screens.first) : nil
    }

    /// True when the frontmost app has a fullscreen window on the given screen.
    static func isFullscreenActive(on screen: NSScreen) -> Bool {
        guard let front = NSWorkspace.shared.frontmostApplication,
              front.bundleIdentifier != Bundle.main.bundleIdentifier,
              let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else {
            return false
        }
        // CG coordinates have their origin at the top-left of the primary screen.
        let primaryHeight = NSScreen.screens.first?.frame.height ?? screen.frame.height
        let target = CGRect(x: screen.frame.minX, y: primaryHeight - screen.frame.maxY, width: screen.frame.width, height: screen.frame.height)
        for info in list {
            guard (info[kCGWindowOwnerPID as String] as? Int32) == front.processIdentifier,
                  (info[kCGWindowLayer as String] as? Int) == 0,
                  let dict = info[kCGWindowBounds as String] as? NSDictionary,
                  let rect = CGRect(dictionaryRepresentation: dict as CFDictionary) else { continue }
            if abs(rect.width - target.width) < 2, abs(rect.height - target.height) < 2,
               abs(rect.minX - target.minX) < 2, abs(rect.minY - target.minY) < 2 {
                return true
            }
        }
        return false
    }
}
