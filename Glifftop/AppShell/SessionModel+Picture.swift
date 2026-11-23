import GliffProtocol
import GliffSession

/// The picture's window sizing, and the cursor shapes the video view shows.
extension SessionModel {
    /// Whether the window has other tabs: its size is the group's, so the session never sizes
    /// it, and a mirror draws fitted to it.
    var sharesWindow: Bool { (tabGroup?.tabs.count ?? 1) > 1 }

    /// The shapes the video view shows: the session's, or (Debug) the test crosshair.
    var viewCursor: CursorSlot {
        #if DEBUG
            if testCursorShape { return TestCursor.slot }
        #endif
        return cursor
    }

    /// A virtual screen fills the screen; a mirror is sized for its first view within its
    /// monitor (`SessionSnapshot.mirrorSize`). Nil until one is known.
    static func windowSizing(for snapshot: SessionSnapshot) -> WindowSizing? {
        if snapshot.session?.headless == true { return .fillScreen }
        guard snapshot.phase == .streaming, let size = snapshot.mirrorSize else { return nil }
        return .monitor(size)
    }
}
