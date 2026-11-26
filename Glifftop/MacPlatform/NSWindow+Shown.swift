import AppKit

extension NSWindow {
    /// The window shown in this one's place: its tab group's selected tab (the only tab of a
    /// group ever shown), else itself.
    var shownTab: NSWindow { tabGroup?.selectedWindow ?? self }

    /// The number of the window shown at `point` (AppKit screen coordinates, mouse-down
    /// hit-testing rules). The window server's answer lags a tab switch: at the new tab's key
    /// edge, and for a frame or so after, it still names the tab just left, which stands for the
    /// tab now selected in its place (`shownTab`).
    static func shownNumber(at point: NSPoint) -> Int {
        let found = windowNumber(at: point, belowWindowWithWindowNumber: 0)
        return NSApp.window(withWindowNumber: found)?.shownTab.windowNumber ?? found
    }
}
