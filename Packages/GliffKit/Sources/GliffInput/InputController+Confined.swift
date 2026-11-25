/// The confined pointer (Capture mode, once the pointer entered the picture): the Mac's
/// deltas move a `VirtualPointer` on the host, which follows the host's own warps; clicks and
/// scrolls land where it is. It ends when confinement does.
extension InputController {
    /// Starts the virtual pointer at (x, y) logical, where the Mac pointer entered, at `time`
    /// (the clock `pointerMoved` and `hostPointer` use). The absolute motions sent just before
    /// count as its own, so their late echoes are no warps. Only while confined, and only once:
    /// an entry reported again keeps it where it is.
    public mutating func confine(x: Double, y: Double, geometry: PictureGeometry, at time: Duration) {
        guard isConfined, virtual == nil, x.isFinite, y.isFinite, let size = geometry.logicalSize else {
            return
        }
        virtual = VirtualPointer(
            x: x, y: y, width: size.width, height: size.height, sent: recentMotions, at: time)
        recentMotions = []
        virtualGeometry = geometry
        unconfinedAt = nil
    }

    /// Ends the virtual pointer, keeping its place in `unconfinedAt`.
    public mutating func unconfine() {
        guard let virtual else { return }
        unconfinedAt = (virtual.x, virtual.y)
        self.virtual = nil
        virtualGeometry = nil
    }

    /// The virtual pointer's position and whether the host shows a pointer; nil unless confined.
    public var confinedPointer: (x: Double, y: Double, visible: Bool)? {
        virtual.map { ($0.x, $0.y, $0.visible) }
    }

    /// A logical delta from the Mac's pointer. Not confined: not consumed, nothing sent. One
    /// that isn't a number is dropped. During the click that took input back, it moves the
    /// virtual pointer but sends nothing: that click's up moves the remote pointer there.
    public mutating func pointerMoved(dx: Double, dy: Double, at time: Duration) -> InputResult {
        guard var pointer = virtual else { return InputResult() }
        guard dx.isFinite, dy.isFinite else { return InputResult(consumed: true) }
        let sent = pointer.move(dx: dx, dy: dy, at: time)
        virtual = pointer
        guard recapturingButton == nil else { return InputResult(consumed: true) }
        return InputResult(consumed: true, messages: move(sent.x, sent.y))
    }

    /// The host's pointer from a CursorPos (capture-buffer pixels). Returns whether the virtual
    /// pointer followed it (a warp); the host is already there, so nothing is sent.
    public mutating func hostPointer(
        bufferX: Double, bufferY: Double, visible: Bool, geometry: PictureGeometry, at time: Duration
    ) -> Bool {
        guard var pointer = virtual,
            let at = FocusTarget.logical(bufferX: bufferX, bufferY: bufferY, geometry: geometry)
        else { return false }
        let adopted = pointer.hostReported(x: at.x, y: at.y, visible: visible, at: time)
        virtual = pointer
        if adopted { remoteAt = (pointer.x, pointer.y) }
        return adopted
    }

    /// A new picture: the virtual pointer stays inside it. The same output in a new stream size
    /// (a mirror fitted anew: the view box and scale unchanged) keeps it on the same host point.
    public mutating func resizeConfined(_ geometry: PictureGeometry) {
        guard virtual != nil, let size = geometry.logicalSize else { return }
        let sameOutput =
            virtualGeometry.map {
                ($0.viewWidth, $0.viewHeight, $0.scaleMilli)
                    == (geometry.viewWidth, geometry.viewHeight, geometry.scaleMilli)
            } ?? false
        virtual?.resize(width: size.width, height: size.height, keepingPlace: sameOutput)
        virtualGeometry = geometry
    }
}
