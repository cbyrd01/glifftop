import AppKit
import GliffInput

/// Capture mode's confined pointer: `InputController.isConfined` holds the Mac pointer over the
/// picture (`PointerConfinement`), whose deltas move the virtual pointer; where the pointer is
/// (`.pointerOnPicture`) and what suspends it.
extension CaptureController {
    /// The confined pointer's clock: the times `InputController` compares.
    var now: Duration { ContinuousClock.now - clockStart }

    /// Starts or stops holding the pointer as `InputController.isConfined` says: after every
    /// result handled.
    func updateConfinement() {
        let wanted = controller?.isConfined ?? false
        if wanted, confinement == nil {
            startConfinement()
        } else if !wanted, let confinement {
            // The pointer comes back where the virtual one was, when the window is on screen.
            let place = controller?.unconfinedAt.flatMap { videoView?.screenPoint(ofRemote: $0) }
            confinement.stop(warpTo: window?.isShownOnActiveSpace == true ? place : nil)
            self.confinement = nil
        }
    }

    /// The virtual pointer where the Mac pointer is over the picture (its centre if it isn't),
    /// then the Mac pointer held. Where it can't be held, the pointer counts as off the picture.
    private func startConfinement() {
        guard confinementAllowed, let videoView, let geometry = videoView.geometry,
            let size = geometry.logicalSize
        else {
            suspendConfinement()
            return
        }
        let at = videoView.macPointerOverPicture() ?? (size.width / 2, size.height / 2)
        controller?.confine(x: at.x, y: at.y, geometry: geometry, at: now)
        guard controller?.confinedPointer != nil else { return }
        let confinement = PointerConfinement(view: videoView) { [weak self] in self?.confined($0, delta: $1) }
        confinement.start()
        guard confinement.isActive else {
            // Nowhere to hold it (the view out of its window): free, and off the picture.
            controller?.unconfine()
            suspendConfinement()
            return
        }
        self.confinement = confinement
    }

    /// A mouse event while confined: motion moves the virtual pointer by `delta` (points),
    /// buttons and scrolls land where it is, with their flags.
    private func confined(_ event: NSEvent, delta: (dx: Double, dy: Double)) {
        guard event.isPointerMotion else {
            if let at = controller?.confinedPointer, let pointerEvent = PointerEvent(event, at: (at.x, at.y))
            {
                _ = pointer(pointerEvent)
            }
            return
        }
        guard let delta = videoView?.remoteDelta(ofPoints: delta),
            let result = controller?.pointerMoved(dx: delta.dx, dy: delta.dy, at: now)
        else { return }
        handle(result)
    }

    /// The video view's hover: on the picture or off it (a repeat changes nothing). Not while
    /// confined: what passes over the frozen pointer (a banner, a window) doesn't end it.
    func hover(_ onPicture: Bool) {
        guard !isConfined else { return }
        report(onPicture && confinementAllowed)
    }

    /// At the window's key edge and the app's active edge: where the pointer is now.
    func reportEntry() {
        report(confinementAllowed && videoView?.macPointerOverPicture() != nil)
    }

    /// `.pointerOnPicture` when it changes (or anything else was applied since).
    private func report(_ onPicture: Bool) {
        guard onPicture != hovering else { return }
        hovering = onPicture
        apply(.pointerOnPicture(onPicture))
    }

    /// The display link's tick: while confined, any condition for holding the pointer lost
    /// suspends it. Leaving ends once this app is in front again with no activation edge (a
    /// late notification of a quick switch away and back).
    func tick() {
        if isConfined, !confinementAllowed { suspendConfinement() }
        if leaving, NSApp.isActive, isFrontmostApp { leaving = false }
    }

    /// Something else took the pointer for now: free it, until it comes back onto the picture.
    func suspendConfinement() {
        // Confined (or its start refused), it goes through even after a report of off the
        // picture: a recapturing click confines without one.
        if controller?.isConfined == true { hovering = nil }
        report(false)
    }

    /// Another app is coming forward: no holding until this one is active and in front again.
    func leave() {
        leaving = true
        suspendConfinement()
    }

    /// This app is about to resign: the pointer free while it is still in front.
    func resign() {
        resigning = true
        suspendConfinement()
    }

    /// Full screen begins (true) or ends (false) its transition: no holding during it.
    func fullScreenTransition(_ on: Bool) {
        transitionStarted = on ? now : nil
        if on { suspendConfinement() }
    }

    /// A full-screen transition under way. One that failed posts no end, so after
    /// `transitionLimit` it counts as over.
    private var inTransition: Bool {
        transitionStarted.map { now - $0 < Self.transitionLimit } ?? false
    }

    /// Longer than any full-screen animation.
    private static let transitionLimit = Duration.seconds(3)

    /// Whether this app is the frontmost one.
    var isFrontmostApp: Bool {
        NSWorkspace.shared.frontmostApplication?.processIdentifier
            == NSRunningApplication.current.processIdentifier
    }

    /// The app active, not leaving or resigning, the window key, on screen on the active Space, out of a
    /// full-screen transition, with no sheet or modal window: the pointer can be held there. No
    /// window-server query.
    private var confinementAllowed: Bool {
        guard let window else { return false }
        return NSApp.isActive && !leaving && !resigning && !inTransition && window.isKeyWindow
            && window.attachedSheet == nil
            && NSApp.modalWindow == nil && window.isShownOnActiveSpace
    }
}

extension NSWindow {
    /// On the active Space and not fully covered or minimised.
    var isShownOnActiveSpace: Bool { isOnActiveSpace && occlusionState.contains(.visible) }
}
