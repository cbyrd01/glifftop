import Testing

@testable import GliffInput

/// The host's reports around confinement's start and a new picture: a pointer hidden at the
/// start keeps its hidden place, and a new stream's reports wait for its picture.
@Suite struct InputControllerHostPictureTests {
    /// 1280×720 logical, one buffer pixel per logical pixel.
    private let geometry = PictureGeometry(
        streamWidth: 1280, streamHeight: 720, viewWidth: 1280, viewHeight: 720, scaleMilli: 1000)
    /// The same output at 2×: 2560×1440 buffer pixels, 1280×720 logical.
    private let doubled = PictureGeometry(
        streamWidth: 2560, streamHeight: 1440, viewWidth: 2560, viewHeight: 1440, scaleMilli: 2000)

    /// Capture mode, captured and confined at (100, 100), hidden at `hiddenAt` (buffer pixels).
    private func confined(hiddenAt: (bufferX: Double, bufferY: Double)? = nil) -> InputController {
        var controller = InputController(mode: .confined, keymap: "k1")
        for event: CaptureEvent in [
            .windowKey(true), .appActive(true), .picture(true), .pointerOnPicture(true),
        ] {
            _ = controller.capture(event)
        }
        controller.confine(x: 100, y: 100, hostHiddenAt: hiddenAt, geometry: geometry, at: .zero)
        return controller
    }

    /// `hostPointer`, callable inside `#expect`.
    private func host(
        _ controller: inout InputController, _ x: Double, _ y: Double, visible: Bool = true,
        geometry: PictureGeometry, at time: Duration
    ) -> Bool {
        controller.hostPointer(bufferX: x, bufferY: y, visible: visible, geometry: geometry, at: time)
    }

    @Test func confiningWhileTheHostHidesItsPointerStartsHidden() {
        let controller = confined(hiddenAt: (500, 300))
        #expect(controller.confinedPointer?.visible == false)
    }

    @Test func theHiddenPlaceReSentOnShowingIsNoWarp() {
        var controller = confined(hiddenAt: (500, 300))
        _ = controller.pointerMoved(dx: 10, dy: 0, at: .zero)
        #expect(!host(&controller, 500, 300, geometry: geometry, at: .seconds(3)))
        #expect(controller.confinedPointer?.x == 110)
        #expect(controller.confinedPointer?.visible == true)
    }

    @Test func aReportBeforeTheNewPictureIsDrawnWaits() {
        var controller = confined()
        controller.hostPictureChanged(at: .zero)
        // In the new stream's pixels, the old picture still drawn: skipped.
        #expect(!host(&controller, 2000, 1000, geometry: geometry, at: .milliseconds(10)))
        #expect(controller.confinedPointer?.x == 100)
    }

    @Test func onceTheNewPictureIsDrawnReportsUseIt() {
        var controller = confined()
        controller.hostPictureChanged(at: .zero)
        #expect(host(&controller, 1000, 600, geometry: doubled, at: .milliseconds(20)))
        #expect(controller.confinedPointer?.x == 500)
        #expect(controller.confinedPointer?.y == 300)
    }

    @Test func aNewPictureOfTheSameGeometryWaitsOnlyItsLimit() {
        var controller = confined()
        controller.hostPictureChanged(at: .zero)
        #expect(!host(&controller, 500, 300, geometry: geometry, at: .milliseconds(10)))
        #expect(host(&controller, 500, 300, geometry: geometry, at: InputController.newPictureLimit))
        #expect(controller.confinedPointer?.x == 500)
    }

    @Test func aReportOfTheOldPictureUsesItEvenOnceTheNewOneIsDrawn() {
        var controller = confined()
        // No new picture announced yet: the report is in the old stream's pixels.
        #expect(host(&controller, 500, 300, geometry: doubled, at: .zero))
        #expect(controller.confinedPointer?.x == 500)
    }
}
