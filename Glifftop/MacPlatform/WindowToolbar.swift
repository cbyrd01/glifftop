import AppKit

/// What the window's toolbar shows, for a menu command that opens a toolbar item's popover.
enum WindowToolbar {
    /// Whether window `number`'s toolbar is on screen: shown, and the window not in full
    /// screen, where it shows only while the pointer is at the top.
    static func isShown(window number: Int?) -> Bool {
        guard let number, let window = NSApp.window(withWindowNumber: number) else { return false }
        return window.toolbar?.isVisible == true && !window.styleMask.contains(.fullScreen)
    }
}
