import GliffInput
import GliffProtocol
import GliffSession
import GliffVideo

/// The picture shown and its window sizing, the cursor shapes the video view shows, the
/// activation target and the view target the remote screen follows.
extension SessionModel {
    /// What the picture is drawn from, while it is shown: streaming, with a stream and a
    /// renderer. The one test for the picture, and for the freely resizable window.
    var picture: (stream: StreamInfo, renderer: PictureRenderer)? {
        guard let renderer else { return nil }
        if let shownStream { return (shownStream, renderer) }
        if let heldPicture { return (heldPicture.stream, renderer) }
        return nil
    }

    /// Sets `hasPicture` when `picture` comes or goes.
    func refreshHasPicture() {
        if hasPicture != (picture != nil) { hasPicture = picture != nil }
    }

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

    /// Where an activation puts the remote pointer (`FocusTarget`): `macPointer` (over the
    /// picture), else the host's pointer, else the centre, over the stream shown. Nil without one.
    func activationTarget(macPointer: (x: Double, y: Double)?) -> (x: Double, y: Double)? {
        guard let stream = picture?.stream else { return nil }
        return FocusTarget.target(
            macPointer: macPointer, cursor: remotePointer.latest.map { ($0.x, $0.y) },
            geometry: stream.pointerGeometry)
    }

    /// A virtual screen fills the screen; a mirror is sized for its first view within its
    /// monitor (`SessionSnapshot.mirrorSize`). Nil until one is known.
    static func windowSizing(for snapshot: SessionSnapshot) -> WindowSizing? {
        if snapshot.session?.headless == true { return .fillScreen }
        guard snapshot.phase == .streaming, let size = snapshot.mirrorSize else { return nil }
        return .monitor(size)
    }

    /// A virtual screen's session that hasn't ended shows no picture yet: its window is sized,
    /// and its size measured, without one (`SessionAreaTracker`).
    var awaitsVirtualPicture: Bool { isVirtual && picture == nil && snapshot.phase != .ended }

    /// The video view's drawable (pixels) and backing scale: the remote screen follows it.
    func viewTargetChanged(_ pixels: PixelSize, backingScale: Double) {
        viewPixels = pixels
        if backingScale != self.backingScale { self.backingScale = backingScale }
        sendViewTarget()
    }

    /// The window's live resize starts or ends: the session sends no Resize during one, and
    /// the size it ended on at once. A session started during one is told so.
    func liveResizeChanged(_ on: Bool) {
        inLiveResize = on
        session?.setLiveResize(on)
    }

    func sendViewTarget() {
        guard let session, let viewPixels, let backingScale else { return }
        session.setViewTarget(
            ViewTarget(
                width: UInt32(clamping: viewPixels.width), height: UInt32(clamping: viewPixels.height),
                backingScale: backingScale, textFactor: textSize.factor, resolution: resolution))
    }
}
