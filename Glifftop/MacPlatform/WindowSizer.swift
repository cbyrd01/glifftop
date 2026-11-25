import AppKit
import GliffVideo

/// How a session's window is sized: for a mirrored monitor's own size, or, for a
/// virtual screen that follows the window, filling the screen.
enum WindowSizing: Equatable {
    case monitor(PixelSize)
    case fillScreen
}

/// Sizes the window for the remote view: 1:1 (one remote pixel per backing pixel) when that
/// fits the screen, else the largest size that fits with the same aspect.
enum WindowSizer {
    /// A virtual screen's window: the screen's visible area, as zoomed.
    static func fill(_ window: NSWindow) {
        guard let screen = screen(for: window) else { return }
        window.setFrame(screen.visibleFrame, display: true, animate: false)
    }

    /// A mirror's window: `view` 1:1 if it fits, with `extraHeight` points of content under the
    /// picture (the status bar); on `target`, at its scale, when the window has just moved there.
    static func fit(_ window: NSWindow, view: PixelSize, extraHeight: CGFloat, on target: NSScreen? = nil) {
        // The video letterboxes inside a full-screen window.
        guard let screen = target ?? screen(for: window) else { return }
        let visible = screen.visibleFrame
        // What the titlebar and toolbar take from the frame, whether or not the content runs
        // under it, and the status bar: the video gets only the rest of the layout rect, so
        // that must be the view's size.
        let covered = NSSize(
            width: window.frame.width - window.contentLayoutRect.width,
            height: window.frame.height - window.contentLayoutRect.height + extraHeight)
        let size = VideoFit.contentSize(
            view: view, backingScale: Double(target?.backingScaleFactor ?? window.backingScaleFactor),
            available: (width: visible.width - covered.width, height: visible.height - covered.height))
        var frame = NSRect(
            x: 0, y: 0, width: size.width + covered.width, height: size.height + covered.height)
        // Keep the top-left corner where it is, then pull the window back onto the screen.
        frame.origin.x = min(max(window.frame.minX, visible.minX), visible.maxX - frame.width)
        frame.origin.y = min(max(window.frame.maxY - frame.height, visible.minY), visible.maxY - frame.height)
        window.setFrame(frame, display: true, animate: false)
    }

    /// A mirror's window `delta` points taller (shorter if negative), its top kept, as the
    /// status bar comes or goes: the picture keeps its size. Pulled back onto the screen, as
    /// `fit` does.
    static func grow(_ window: NSWindow, by delta: CGFloat) {
        guard let screen = screen(for: window) else { return }
        let visible = screen.visibleFrame
        var frame = window.frame
        frame.size.height = min(frame.height + delta, visible.height)
        frame.origin.y = min(max(window.frame.maxY - frame.height, visible.minY), visible.maxY - frame.height)
        window.setFrame(frame, display: true, animate: false)
    }

    /// The window's screen, or nil when it's full screen: a full-screen window keeps its screen.
    private static func screen(for window: NSWindow) -> NSScreen? {
        guard !window.styleMask.contains(.fullScreen) else { return nil }
        return window.screen ?? NSScreen.main
    }
}
