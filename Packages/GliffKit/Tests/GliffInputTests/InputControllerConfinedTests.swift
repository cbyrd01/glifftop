import Testing

@testable import GliffInput

/// The confined pointer through the controller: deltas move it, the host's warps move it,
/// clicks land where it is, and it ends with confinement.
@Suite struct InputControllerConfinedTests {
    /// 1280×720 logical, one buffer pixel per logical pixel.
    private let geometry = PictureGeometry(
        streamWidth: 1280, streamHeight: 720, viewWidth: 1280, viewHeight: 720, scaleMilli: 1000)

    /// Capture mode, captured, the pointer entered at (100, 100).
    private func confined() -> InputController {
        var controller = InputController(mode: .confined, keymap: "k1")
        for event: CaptureEvent in [
            .windowKey(true), .appActive(true), .picture(true), .pointerOnPicture(true),
        ] {
            _ = controller.capture(event)
        }
        controller.confine(x: 100, y: 100, geometry: geometry, at: .zero)
        return controller
    }

    /// `hostPointer`, callable inside `#expect`.
    private func host(
        _ controller: inout InputController, bufferX: Double, bufferY: Double, visible: Bool,
        geometry: PictureGeometry, at time: Duration
    ) -> Bool {
        controller.hostPointer(
            bufferX: bufferX, bufferY: bufferY, visible: visible, geometry: geometry, at: time)
    }

    @Test func aDeltaSendsTheVirtualPosition() {
        var controller = confined()
        let result = controller.pointerMoved(dx: 10, dy: 0, at: .zero)
        #expect(result.consumed)
        #expect(result.messages == [.pointerMotion(x: 110, y: 100)])
        #expect(controller.confinedPointer?.x == 110)
    }

    @Test func deltasPastAnEdgeStayInside() {
        var controller = confined()
        #expect(
            controller.pointerMoved(dx: -500, dy: 5000, at: .zero).messages == [.pointerMotion(x: 0, y: 719)])
    }

    @Test func aHostWarpIsFollowed() {
        var controller = confined()
        #expect(
            host(&controller, bufferX: 500, bufferY: 300, visible: true, geometry: geometry, at: .zero))
        #expect(
            controller.pointerMoved(dx: 10, dy: 0, at: .milliseconds(10)).messages == [
                .pointerMotion(x: 510, y: 300)
            ])
    }

    @Test func anEchoDoesNotPullBack() {
        var controller = confined()
        _ = controller.pointerMoved(dx: 10, dy: 0, at: .zero)
        _ = controller.pointerMoved(dx: 10, dy: 0, at: .milliseconds(10))
        #expect(
            !host(
                &controller,
                bufferX: 110, bufferY: 100, visible: true, geometry: geometry, at: .milliseconds(20)))
        #expect(controller.confinedPointer?.x == 120)
    }

    @Test func notConfinedSendsNothing() {
        var controller = capturedController()
        let result = controller.pointerMoved(dx: 10, dy: 0, at: .zero)
        #expect(!result.consumed)
        #expect(result.messages.isEmpty)
        #expect(controller.confinedPointer == nil)
        #expect(!host(&controller, bufferX: 1, bufferY: 1, visible: true, geometry: geometry, at: .zero))
    }

    /// Confinement waits for the pointer's entry: confine before it does nothing.
    @Test func confineBeforeTheEntryDoesNothing() {
        var controller = InputController(mode: .confined, keymap: "k1")
        for event: CaptureEvent in [.windowKey(true), .appActive(true), .picture(true)] {
            _ = controller.capture(event)
        }
        controller.confine(x: 100, y: 100, geometry: geometry, at: .zero)
        #expect(controller.confinedPointer == nil)
    }

    /// The Mac pointer stays put while confined: a click lands at the virtual position.
    @Test func aClickAtTheVirtualPositionSendsNoExtraMotion() {
        var controller = confined()
        _ = controller.pointerMoved(dx: 10, dy: 0, at: .zero)
        let click = controller.pointer(.button(number: 0, pressed: true, x: 5, y: 5, flags: 0))
        #expect(click.messages == [.pointerButton(code: 0x110, pressed: true)])
    }

    /// Motion from the Mac pointer's place isn't the virtual pointer's: deltas move it.
    @Test func absoluteMotionIsIgnoredWhileConfined() {
        var controller = confined()
        let result = controller.pointer(.moved(x: 5, y: 5))
        #expect(result.consumed)
        #expect(result.messages.isEmpty)
    }

    @Test func fallingCaptureUnconfines() {
        var controller = confined()
        _ = controller.capture(.windowKey(false))
        #expect(controller.confinedPointer == nil)
        _ = controller.capture(.windowKey(true))
        #expect(controller.confinedPointer == nil)
    }

    @Test func aNewSizeKeepsItInside() {
        var controller = confined()
        _ = controller.pointerMoved(dx: 1000, dy: 0, at: .zero)
        controller.resizeConfined(
            PictureGeometry(
                streamWidth: 1024, streamHeight: 768, viewWidth: 1024, viewHeight: 768, scaleMilli: 1000))
        #expect(controller.confinedPointer?.x == 1023)
    }

    /// A mirror fitted into a new stream size shows the same output: the virtual pointer
    /// stays on the same host point.
    @Test func aMirrorsNewStreamSizeKeepsTheHostPoint() {
        let mirror = PictureGeometry(
            streamWidth: 1280, streamHeight: 720, viewWidth: 2560, viewHeight: 1440, scaleMilli: 1000)
        var controller = InputController(mode: .confined, keymap: "k1")
        for event: CaptureEvent in [
            .windowKey(true), .appActive(true), .picture(true), .pointerOnPicture(true),
        ] {
            _ = controller.capture(event)
        }
        controller.confine(x: 600, y: 300, geometry: mirror, at: .zero)
        var refit = mirror
        (refit.streamWidth, refit.streamHeight) = (640, 360)
        controller.resizeConfined(refit)
        #expect(controller.confinedPointer?.x == 300)
        #expect(controller.confinedPointer?.y == 150)
    }

    /// Capture mode after ⇧Esc: the click that takes input back confines at its point, and,
    /// as in Integrated, nothing from the pointer is sent until its up, which moves the remote
    /// pointer to where it was let go: the virtual pointer, dragged on.
    @Test func aRecapturingClickSendsNothingUntilItsUp() {
        var controller = confined()
        _ = controller.capture(.release)
        _ = controller.pointer(.button(number: 0, pressed: true, x: 5, y: 5, flags: 0))
        _ = controller.capture(.pointerOnPicture(true))
        controller.confine(x: 5, y: 5, geometry: geometry, at: .zero)
        let drag = controller.pointerMoved(dx: 10, dy: 0, at: .zero)
        #expect(drag.consumed)
        #expect(drag.messages.isEmpty)
        let up = controller.pointer(.button(number: 0, pressed: false, x: 5, y: 5, flags: 0))
        #expect(up.messages == [.pointerMotion(x: 15, y: 5)])
    }

    /// The app reports the entry again: the virtual pointer stays where it is.
    @Test func confiningAgainKeepsThePointer() {
        var controller = confined()
        _ = controller.pointerMoved(dx: 10, dy: 0, at: .zero)
        controller.confine(x: 100, y: 100, geometry: geometry, at: .zero)
        #expect(controller.confinedPointer?.x == 110)
    }

    @Test func aNonFiniteDeltaSendsNothing() {
        var controller = confined()
        for (dx, dy) in [(Double.nan, 0.0), (0, .infinity)] {
            #expect(controller.pointerMoved(dx: dx, dy: dy, at: .zero).messages.isEmpty)
        }
        #expect(controller.confinedPointer?.x == 100)
        var fresh = InputController(mode: .confined, keymap: "k1")
        for event: CaptureEvent in [
            .windowKey(true), .appActive(true), .picture(true), .pointerOnPicture(true),
        ] {
            _ = fresh.capture(event)
        }
        fresh.confine(x: .nan, y: 100, geometry: geometry, at: .zero)
        #expect(fresh.confinedPointer == nil)
    }

    /// Confinement ends with capture; where the virtual pointer was stays, for the app to put
    /// the Mac cursor there.
    @Test func unconfiningKeepsWhereItWas() {
        var controller = confined()
        _ = controller.pointerMoved(dx: 10, dy: 0, at: .zero)
        _ = controller.capture(.windowKey(false))
        #expect(controller.unconfinedAt?.x == 110)
        #expect(controller.unconfinedAt?.y == 100)
        _ = controller.capture(.windowKey(true))
        _ = controller.capture(.pointerOnPicture(true))
        controller.confine(x: 1, y: 1, geometry: geometry, at: .zero)
        #expect(controller.unconfinedAt == nil)
    }

    /// The motions sent as the pointer came onto the picture echo after confinement starts:
    /// they're no warps.
    @Test func theEntrysOwnMotionsAreEchoes() {
        var controller = InputController(mode: .confined, keymap: "k1")
        for event: CaptureEvent in [.windowKey(true), .appActive(true), .picture(true)] {
            _ = controller.capture(event)
        }
        _ = controller.pointer(.moved(x: 0, y: 280))
        _ = controller.pointer(.moved(x: 0, y: 290))
        _ = controller.capture(.pointerOnPicture(true))
        controller.confine(x: 0, y: 300, geometry: geometry, at: .seconds(5))
        let late = Duration.seconds(5) + .milliseconds(30)
        #expect(!host(&controller, bufferX: 0, bufferY: 280, visible: true, geometry: geometry, at: late))
        #expect(!host(&controller, bufferX: 0, bufferY: 290, visible: true, geometry: geometry, at: late))
        #expect(controller.confinedPointer?.y == 300)
    }

    /// The activation's nudge echoes too.
    @Test func theNudgeIsAnEcho() {
        var controller = InputController(mode: .confined, keymap: "k1")
        for event: CaptureEvent in [.windowKey(true), .appActive(true), .picture(true)] {
            _ = controller.capture(event)
        }
        _ = controller.activate(at: (x: 640, y: 360))
        _ = controller.capture(.pointerOnPicture(true))
        controller.confine(x: 0, y: 300, geometry: geometry, at: .zero)
        #expect(!host(&controller, bufferX: 639, bufferY: 360, visible: true, geometry: geometry, at: .zero))
        #expect(controller.confinedPointer?.x == 0)
    }

    /// A captured key may move the host's pointer: the motions before it are no echoes then.
    @Test func aKeyForgetsTheMotionsBefore() {
        var controller = InputController(mode: .confined, keymap: "k1")
        for event: CaptureEvent in [.windowKey(true), .appActive(true), .picture(true)] {
            _ = controller.capture(event)
        }
        _ = controller.activate(at: (x: 640, y: 360))
        _ = controller.key(down(0x00))
        _ = controller.capture(.pointerOnPicture(true))
        controller.confine(x: 0, y: 300, geometry: geometry, at: .zero)
        #expect(host(&controller, bufferX: 639, bufferY: 360, visible: true, geometry: geometry, at: .zero))
    }

    /// Leaving the picture forgets them too.
    @Test func leavingThePictureForgetsTheMotions() {
        var controller = InputController(mode: .confined, keymap: "k1")
        for event: CaptureEvent in [.windowKey(true), .appActive(true), .picture(true)] {
            _ = controller.capture(event)
        }
        _ = controller.activate(at: (x: 640, y: 360))
        _ = controller.capture(.pointerOnPicture(false))
        #expect(controller.recentMotions.isEmpty)
    }

    /// Integrated never confines: it keeps no motions.
    @Test func integratedKeepsNoMotions() {
        var controller = capturedController()
        _ = controller.pointer(.moved(x: 5, y: 5))
        _ = controller.activate(at: (x: 640, y: 360))
        #expect(controller.recentMotions.isEmpty)
    }

    /// The host shows its pointer or not, as its CursorPos says.
    @Test func theHostsVisibilityShowsThrough() {
        var controller = confined()
        _ = controller.hostPointer(bufferX: 100, bufferY: 100, visible: false, geometry: geometry, at: .zero)
        #expect(controller.confinedPointer?.visible == false)
    }
}
