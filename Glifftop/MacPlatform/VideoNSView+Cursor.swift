import AppKit
import GliffInput
import GliffSession
import os

/// The pointer's look over the picture (`VideoNSView`): the picture's cursor while focused and
/// over it, given back off it, and the focus that decides.
extension VideoNSView {
    /// Motion, a drag's too (one goes on after ⌘Tab): on the picture, focused, its cursor; else given back.
    @discardableResult func followPointer(_ event: NSEvent) -> Bool {
        let hit = isHit(at: event.locationInWindow)
        if hit, isFocused { showCursor() } else { giveBackCursor() }
        return hit
    }

    /// A drag from the picture ends where it was let go, maybe over an overlay, with no motion
    /// to say so: the cursor is checked again there.
    func buttonUp() {
        let wasHere = pressedHere
        pressedHere = NSEvent.pressedMouseButtons != 0
        if wasHere, !pressedHere { refreshCursor() }
    }

    // The window or the app losing focus: the pointer's events go elsewhere now, so the
    // picture's cursor mustn't stay behind for them. The app's loss is taken while it is still
    // active (`will`), as a background app's cursor change may not reach the screen, and from
    // then on nothing shows the picture's. The display link checks again once back in focus.
    @objc func focusLost(_ notification: Notification) {
        if notification.name == NSApplication.willResignActiveNotification { focusLeaving = true }
        giveBackCursor()
        cursorPending = true
    }

    // Back in focus: the picture's cursor again under a pointer that hasn't moved.
    @objc func focusGained(_ notification: Notification) {
        if notification.name == NSApplication.didBecomeActiveNotification { focusLeaving = false }
        refreshCursor()
    }

    /// The session's shapes, whether input is captured and the video carries the pointer: the
    /// cursor changes at once if the pointer is over the picture.
    func updateCursor(slot: CursorSlot, captured: Bool, videoHasPointer: Bool) {
        guard cursor.slot !== slot || cursor.captured != captured || cursor.videoHasPointer != videoHasPointer
        else {
            return
        }
        (cursor.slot, cursor.captured, cursor.videoHasPointer) = (slot, captured, videoHasPointer)
        refreshCursor()
    }

    /// Whether this window would get the pointer's events: key, the app active and not leaving.
    private var isFocused: Bool {
        window?.isKeyWindow == true && NSApplication.shared.isActive && !focusLeaving
    }

    /// Shows the cursor for now (capture, the session, the shape, its size) under a resting
    /// pointer: the picture's on the picture, given back elsewhere (the interruption panel,
    /// outside a view that shrank). Only `isFocused` and out of a live resize (its edge cursor
    /// is the window's); otherwise pending for the display link, and out of focus given back.
    func refreshCursor() {
        guard let window, isFocused, !window.inLiveResize else {
            if !isFocused { giveBackCursor() }
            cursorPending = true
            return
        }
        cursorPending = false
        if isHit(at: window.mouseLocationOutsideOfEventStream) { showCursor() } else { giveBackCursor() }
    }

    /// Sets the picture's cursor: the only place the picture's own cursor is set, so the claim
    /// always holds the one shown. The arrow (released, or no shape) isn't claimed.
    func showCursor() {
        let shown = cursor.current(pointsPerPixel: cursorPointsPerPixel())
        shown.set()
        let claimed = shown === NSCursor.arrow ? nil : shown
        if claimed !== claim.shown {
            Self.cursorLogger.debug(
                "the picture's cursor: \(claimed == nil ? "arrow" : "claimed", privacy: .public)")
        }
        claim.show(claimed)
    }

    /// The pointer stopped being the picture's: the arrow, if the cursor shown is still the
    /// picture's (the hidden one must never follow the pointer off it). One set since by
    /// AppKit, an overlay or another window stays. The arrow set here is never claimed. In a
    /// live resize the claim waits, and the display link checks again after it.
    func giveBackCursor(evenInLiveResize: Bool = false) {
        let resizing = !evenInLiveResize && window?.inLiveResize == true
        guard claim.giveBack(current: NSCursor.current, liveResize: resizing) else {
            if resizing, claim.shown != nil { cursorPending = true }
            return
        }
        NSCursor.arrow.set()
        Self.cursorLogger.debug("the picture's cursor given back")
    }

    /// Whether `location` (in the window) is over this view: this window is the frontmost at
    /// that point on screen (not the Dock, a floating window, or the menu bar shown in full
    /// screen), and its hit test finds this view, not an overlay.
    func isHit(at location: NSPoint) -> Bool {
        guard isFrontmost(at: location), let content = window?.contentView else { return false }
        let point = content.superview?.convert(location, from: nil) ?? location
        return content.hitTest(point) === self
    }

    /// Whether this window, not another app's or another of ours, is the one at `location`
    /// (window coordinates) on screen.
    private func isFrontmost(at location: NSPoint) -> Bool {
        guard let window else { return false }
        return NSWindow.windowNumber(
            at: window.convertPoint(toScreen: location), belowWindowWithWindowNumber: 0)
            == window.windowNumber
    }
}
