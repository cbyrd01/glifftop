import Testing

@testable import GliffVideo

struct RedrawTrackerTests {
    private let size = PixelSize(width: 2560, height: 1440)

    @Test func nothingToDrawWithoutAPicture() {
        let tracker = RedrawTracker()
        #expect(!tracker.needsDraw(generation: nil, drawable: size, view: size, scaleToFit: false))
    }

    @Test func aNewPictureIsDrawnOnce() {
        var tracker = RedrawTracker()
        #expect(tracker.needsDraw(generation: 1, drawable: size, view: size, scaleToFit: false))
        tracker.drew(generation: 1, drawable: size, view: size, scaleToFit: false)
        #expect(!tracker.needsDraw(generation: 1, drawable: size, view: size, scaleToFit: false))
        #expect(tracker.needsDraw(generation: 2, drawable: size, view: size, scaleToFit: false))
    }

    /// A resize redraws the same picture into the new drawable.
    @Test func aNewDrawableSizeRedraws() {
        var tracker = RedrawTracker()
        tracker.drew(generation: 1, drawable: size, view: size, scaleToFit: false)
        #expect(
            tracker.needsDraw(
                generation: 1, drawable: PixelSize(width: 1280, height: 720), view: size, scaleToFit: false))
    }

    /// A view-only StreamConfig moves the picture on screen to a new box: redraw it.
    @Test func aNewViewSizeRedraws() {
        var tracker = RedrawTracker()
        tracker.drew(generation: 1, drawable: size, view: size, scaleToFit: false)
        #expect(!tracker.needsDraw(generation: 1, drawable: size, view: size, scaleToFit: false))
        #expect(
            tracker.needsDraw(
                generation: 1, drawable: size, view: PixelSize(width: 5120, height: 2880), scaleToFit: false))
    }

    /// Turning Scale to Fit on or off moves the picture: redraw it.
    @Test func aScaleToFitToggleRedraws() {
        var tracker = RedrawTracker()
        tracker.drew(generation: 1, drawable: size, view: size, scaleToFit: false)
        #expect(tracker.needsDraw(generation: 1, drawable: size, view: size, scaleToFit: true))
        tracker.drew(generation: 1, drawable: size, view: size, scaleToFit: true)
        #expect(!tracker.needsDraw(generation: 1, drawable: size, view: size, scaleToFit: true))
    }

    /// A draw that failed isn't recorded, so the next tick tries again.
    @Test func anUnrecordedDrawIsRetried() {
        let tracker = RedrawTracker()
        #expect(tracker.needsDraw(generation: 1, drawable: size, view: size, scaleToFit: false))
        #expect(tracker.needsDraw(generation: 1, drawable: size, view: size, scaleToFit: false))
    }
}
