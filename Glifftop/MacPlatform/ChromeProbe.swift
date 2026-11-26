import AppKit
import GliffInput

/// Where a key event happened, for Integrated's ⌘ routing: gathers `PointerPlace.Facts` at
/// the event's location and lets `PointerPlace.classify` decide.
enum ChromeProbe {
    /// The place of `event`'s location for the key session window `keyWindow`, whose picture
    /// `videoView` shows. With no location the picture, so keys go to the host.
    @MainActor static func place(of event: NSEvent, keyWindow: NSWindow, videoView: VideoNSView)
        -> PointerPlace
    {
        guard let location = event.cgEvent?.location else { return .picture }
        let point = ScreenCoordinates.appKit(fromGlobal: location)
        let facts = PointerPlace.Facts(
            dragFromPicture: videoView.pressedHere && NSEvent.pressedMouseButtons != 0,
            window: window(at: point, keyWindow: keyWindow, videoView: videoView),
            inMenuBarStrip: inMenuBarStrip(point))
        return PointerPlace.classify(facts)
    }

    /// The window under `point` (mouse-down hit-testing rules), as it relates to the key
    /// session window. Over the key window, the video view's frame decides: the window number
    /// can't tell the content from the title bar or toolbar.
    @MainActor private static func window(
        at point: NSPoint, keyWindow: NSWindow, videoView: VideoNSView
    ) -> PointerPlace.Facts.Window {
        let number = NSWindow.shownNumber(at: point)
        if number == keyWindow.windowNumber {
            // The resize margin hit-tests as the window but lies outside its frame: outside.
            guard NSMouseInRect(point, keyWindow.frame, false) else { return .notOurs }
            let inVideoView = videoView.frameOnScreen.map { NSMouseInRect(point, $0, false) } ?? false
            return .keySession(inVideoView: inVideoView)
        }
        guard let window = NSApp.window(withWindowNumber: number) else { return .notOurs }
        var parent = window.parent
        while let current = parent {
            if current === keyWindow { return .attachedToKeySession }
            parent = current.parent
        }
        return .otherOfOurs
    }

    /// The menu bar's strip at the top of the screen `point` is on, shown or revealed: the menu
    /// bar's height (the status bar's thickness while it is hidden), or the screen's top inset
    /// where a camera housing makes the bar taller. Only a screen with a menu bar: each one
    /// with separate Spaces, else the first.
    @MainActor private static func inMenuBarStrip(_ point: NSPoint) -> Bool {
        let screens =
            NSScreen.screensHaveSeparateSpaces ? NSScreen.screens : Array(NSScreen.screens.prefix(1))
        guard let screen = screens.first(where: { NSMouseInRect(point, $0.frame, false) }) else {
            return false
        }
        let height = max(
            NSApp.mainMenu?.menuBarHeight ?? 0, NSStatusBar.system.thickness, screen.safeAreaInsets.top)
        return point.y >= screen.frame.maxY - height
    }
}
