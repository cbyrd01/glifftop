import AppKit
import GliffMachines
import GliffVideo

/// Show as Windows' placement on the Mac's displays (`MonitorPlacement` decides, this applies):
/// the displays as plain rectangles, a window put at its slot, and the key window moved to its
/// own. A display gone by then leaves the window where macOS put it.
enum WindowPlacement {
    /// The Mac's displays, by their `NSScreenNumber`.
    static func displays() -> [DisplayRect] {
        NSScreen.screens.compactMap { screen in
            number(of: screen).map { DisplayRect(id: $0, minX: screen.frame.minX, maxY: screen.frame.maxY) }
        }
    }

    /// Whether window `number` can move to its slot: not in full screen (a window shared by
    /// tabs is the caller's to rule out).
    static func isMovable(_ number: Int) -> Bool {
        NSApp.window(withWindowNumber: number).map { !$0.styleMask.contains(.fullScreen) } ?? false
    }

    /// Puts `window`'s top-left `step` cascade steps from display `display`'s visible frame's
    /// top-left; left where it is when no such display is connected.
    static func place(_ window: NSWindow, display: UInt32, step: Int) {
        guard let screen = screen(display) else { return }
        place(window, on: screen, step: step)
    }

    /// The key window `number`, a mirror showing `view`, moved to its slot, then fitted to its
    /// new display as a mirror's first fit is (`WindowSizer.fit`), at that display's scale: the
    /// window's own backing scale may follow only later.
    static func move(_ number: Int, display: UInt32, step: Int, view: PixelSize, extraHeight: CGFloat) {
        guard let window = NSApp.window(withWindowNumber: number), let screen = screen(display) else {
            return
        }
        place(window, on: screen, step: step)
        WindowSizer.fit(window, view: view, extraHeight: extraHeight, on: screen)
    }

    /// Puts `window`'s top-left `steps` cascade steps from `topLeft`.
    static func cascade(_ window: NSWindow, from topLeft: NSPoint, steps: Int) {
        // `cascadeTopLeft(from:)` leaves the window where it is for the zero point (a display's
        // corner can be): the first place is set directly. Each call with a point puts the
        // window there; each returns the next step's.
        window.setFrameTopLeftPoint(topLeft)
        var point = window.cascadeTopLeft(from: .zero)
        for _ in 0..<steps { point = window.cascadeTopLeft(from: point) }
    }

    private static func screen(_ display: UInt32) -> NSScreen? {
        NSScreen.screens.first { number(of: $0) == display }
    }

    private static func place(_ window: NSWindow, on screen: NSScreen, step: Int) {
        cascade(window, from: NSPoint(x: screen.visibleFrame.minX, y: screen.visibleFrame.maxY), steps: step)
    }

    private static func number(of screen: NSScreen) -> UInt32? {
        (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value
    }
}
