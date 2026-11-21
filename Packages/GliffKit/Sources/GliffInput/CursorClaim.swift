/// The cursor the picture last showed, so that only it is ever taken back. When the pointer
/// stops being the picture's (it moves off, the window or app loses focus, the picture goes),
/// the arrow replaces the cursor shown only if that is still the picture's: one set since, by
/// the toolkit, an overlay or another window, is left alone. Cursors compare by identity, so
/// every cursor the picture sets must go through `show`, and the shared system arrow is never
/// claimed (`show(nil)`).
public struct CursorClaim<Cursor: AnyObject> {
    public private(set) var shown: Cursor?

    public init() {}

    /// The picture shows `cursor` now; nil when what it shows isn't its own (the system arrow,
    /// which the toolkit and overlays set too), which ends the claim.
    public mutating func show(_ cursor: Cursor?) {
        shown = cursor
    }

    /// The pointer stopped being the picture's: true when `current` is still the cursor it
    /// showed, so the caller sets the arrow. The claim ends either way, except during a live
    /// resize (false, kept): the edge's cursor is the window's then, and the give-back after
    /// the resize still works.
    public mutating func giveBack(current: Cursor?, liveResize: Bool) -> Bool {
        guard !liveResize, let shown else { return false }
        self.shown = nil
        return current === shown
    }
}
