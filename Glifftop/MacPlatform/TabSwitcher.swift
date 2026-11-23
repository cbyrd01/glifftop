import AppKit
import GliffInput

/// ⌘⇧[ and ⌘⇧]: the previous or next tab of the window; in a window of one tab, the previous
/// or next Glifftop window (its Space comes forward); with one window, nothing.
enum TabSwitcher {
    /// `window` and `order` are window numbers: the session window the chord came from, and
    /// every session window in opening order.
    static func select(_ chord: TabChord, from window: Int?, order: [Int]) {
        // Held down, it moves once: the menu's shortcut sees every repeat.
        if let event = NSApp.currentEvent, event.type == .keyDown, event.isARepeat { return }
        guard let number = window, let window = NSApp.window(withWindowNumber: number) else { return }
        if (window.tabbedWindows?.count ?? 1) > 1 {
            chord == .next ? window.selectNextTab(nil) : window.selectPreviousTab(nil)
            return
        }
        // One entry per window: a tab group counts once, as its selected tab.
        var seen: Set<ObjectIdentifier> = []
        let windows = order.compactMap { NSApp.window(withWindowNumber: $0) }.compactMap {
            other -> NSWindow? in
            guard seen.insert(group(of: other)).inserted else { return nil }
            return other.tabGroup?.selectedWindow ?? other
        }
        guard windows.count > 1, let index = windows.firstIndex(where: { group(of: $0) == group(of: window) })
        else { return }
        let step = chord == .next ? 1 : windows.count - 1
        windows[(index + step) % windows.count].makeKeyAndOrderFront(nil)
    }

    private static func group(of window: NSWindow) -> ObjectIdentifier {
        window.tabGroup.map(ObjectIdentifier.init) ?? ObjectIdentifier(window)
    }
}
