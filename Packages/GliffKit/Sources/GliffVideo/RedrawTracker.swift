/// When a video view must draw: a picture it hasn't drawn yet, a drawable of a new size, a
/// picture whose view box changed (a view-only StreamConfig moves the one on screen too), or
/// Scale to Fit turned on or off.
/// Between those, the last frame stays on screen and the GPU does nothing.
public struct RedrawTracker: Sendable {
    private var last: (generation: UInt64, drawable: PixelSize, view: PixelSize, scaleToFit: Bool)?

    public init() {}

    /// Whether `generation` (the slot's, nil before the first picture), showing remote `view`,
    /// needs drawing into a `drawable`-sized target.
    public func needsDraw(
        generation: UInt64?, drawable: PixelSize, view: PixelSize, scaleToFit: Bool
    ) -> Bool {
        guard let generation else { return false }
        return last.map { $0 != (generation, drawable, view, scaleToFit) } ?? true
    }

    /// Records a draw that was committed.
    public mutating func drew(
        generation: UInt64, drawable: PixelSize, view: PixelSize, scaleToFit: Bool
    ) {
        last = (generation, drawable, view, scaleToFit)
    }
}
