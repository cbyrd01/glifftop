import GliffProtocol
import Testing

@testable import GliffInput

/// The pointer under the same capture as the keys: sent only while captured, its buttons in
/// the ledger, and the click that takes input back never reaching the remote. Presses and
/// scrolls carry where they happened: away from where the remote pointer was left, it is
/// moved there first.
@Suite struct InputControllerPointerTests {
    /// Captured, with the remote pointer at (0, 0).
    private func captured() -> InputController {
        var controller = capturedController()
        _ = controller.pointer(.moved(x: 0, y: 0))
        return controller
    }

    private func button(_ number: Int, _ pressed: Bool, at point: (Double, Double) = (0, 0)) -> PointerEvent {
        .button(number: number, pressed: pressed, x: point.0, y: point.1, flags: 0)
    }

    private func scroll(
        _ deltaY: Double = 2, phase: ScrollPhase = .changed, at point: (Double, Double) = (0, 0)
    ) -> PointerEvent {
        .scroll(
            ScrollEvent(deltaX: 0, deltaY: deltaY, isPrecise: true, phase: phase, isMomentum: false),
            x: point.0, y: point.1, flags: 0)
    }

    private let axis = InputMessage.pointerAxis(axis: .vertical, value: -2, discrete: nil, stop: false)

    private func shiftEsc(_ controller: inout InputController) -> InputResult {
        controller.key(
            MacKeyEvent(
                keyCode: 0x35, kind: .down(isRepeat: false),
                flags: MacModifierFlags([.shift, .leftShift]).rawValue))
    }

    private let left = InputMessage.pointerButton(code: 0x110, pressed: true)
    private let leftUp = InputMessage.pointerButton(code: 0x110, pressed: false)

    @Test func capturedMotionIsSent() {
        var controller = captured()
        let result = controller.pointer(.moved(x: 10, y: 20))
        #expect(result == InputResult(consumed: true, messages: [.pointerMotion(x: 10, y: 20)]))
    }

    @Test func aClickIsAPressAndARelease() {
        var controller = captured()
        #expect(controller.pointer(button(0, true)).messages == [left])
        #expect(controller.pointer(button(0, false)).messages == [leftUp])
    }

    @Test func anUnknownButtonIsConsumedAndSendsNothing() {
        var controller = captured()
        #expect(controller.pointer(button(8, true)) == InputResult(consumed: true))
    }

    @Test func theRecapturingClickIsNotSent() {
        var controller = captured()
        _ = shiftEsc(&controller)
        #expect(!controller.isCaptured)
        let down = controller.pointer(button(0, true))
        #expect(down.consumed && down.messages.isEmpty && down.showHint)
        #expect(controller.isCaptured)
        #expect(controller.pointer(.moved(x: 5, y: 5)) == InputResult(consumed: true))
        #expect(
            controller.pointer(button(0, false))
                == InputResult(consumed: true, messages: [.pointerMotion(x: 0, y: 0)]))
        #expect(controller.pointer(.moved(x: 6, y: 6)).messages == [.pointerMotion(x: 6, y: 6)])
        #expect(controller.pointer(button(0, true, at: (6, 6))).messages == [left])
    }

    /// The recapturing click's up went elsewhere (the window lost key mid-click): its button
    /// is forgotten, so motion isn't swallowed once input is captured again.
    @Test func aRecapturingClickCutShortIsForgotten() {
        var controller = captured()
        _ = shiftEsc(&controller)
        _ = controller.pointer(button(0, true))
        _ = controller.capture(.windowKey(false))
        _ = controller.capture(.windowKey(true))
        #expect(controller.pointer(.moved(x: 3, y: 4)).messages == [.pointerMotion(x: 3, y: 4)])
    }

    @Test func releaseLetsGoOfButtonsToo() {
        var controller = captured()
        _ = controller.pointer(button(0, true))
        #expect(shiftEsc(&controller).messages.contains(leftUp))
        #expect(controller.pointer(.moved(x: 1, y: 1)) == InputResult())
    }

    @Test func aButtonHeldPastTheEdgeIsReleasedByItsUp() {
        var controller = captured()
        _ = controller.pointer(button(0, true))
        #expect(controller.pointer(.moved(x: -50, y: -50)).messages == [.pointerMotion(x: -50, y: -50)])
        #expect(controller.pointer(button(0, false, at: (-50, -50))).messages == [leftUp])
    }

    @Test func resigningKeyMidDragReleasesTheButton() {
        var controller = captured()
        _ = controller.pointer(button(0, true))
        #expect(controller.capture(.windowKey(false)).messages == [leftUp])
        #expect(controller.pointer(button(0, false)).messages.isEmpty)
    }

    @Test func scrollIsSentWhileCaptured() {
        var controller = captured()
        #expect(
            controller.pointer(scroll())
                == InputResult(
                    consumed: true,
                    messages: [.pointerAxis(axis: .vertical, value: -2, discrete: nil, stop: false)]))
    }

    @Test func notCapturedSendsNothing() {
        var controller = InputController(keymap: "k1")
        for event: PointerEvent in [.moved(x: 1, y: 1), scroll(), button(0, false)] {
            #expect(controller.pointer(event) == InputResult(), "\(event)")
        }
    }

    /// Motion isn't sent during the recapturing click: its up moves the remote pointer to
    /// where it was let go, so keys typed next go where the Mac's pointer is.
    @Test func theRecapturingClicksUpMovesThePointerThere() {
        var controller = captured()
        _ = shiftEsc(&controller)
        _ = controller.pointer(button(0, true, at: (900, 500)))
        #expect(controller.pointer(.moved(x: 901, y: 501)) == InputResult(consumed: true))
        let up = controller.pointer(button(0, false, at: (901, 501)))
        #expect(up == InputResult(consumed: true, messages: [.pointerMotion(x: 901, y: 501)]))
        #expect(controller.pointer(button(0, true, at: (901, 501))).messages == [left])
    }

    /// No motion arrives while the window isn't key: a press elsewhere moves the pointer first.
    @Test func aPressAwayFromTheRemotePointerMovesItFirst() {
        var controller = captured()
        _ = controller.capture(.windowKey(false))
        _ = controller.capture(.windowKey(true))
        #expect(
            controller.pointer(button(0, true, at: (5, 5))).messages == [.pointerMotion(x: 5, y: 5), left])
        #expect(controller.pointer(button(0, false, at: (5, 5))).messages == [leftUp])
    }

    @Test func aScrollAwayFromTheRemotePointerMovesItFirst() {
        var controller = captured()
        #expect(controller.pointer(scroll(at: (5, 5))).messages == [.pointerMotion(x: 5, y: 5), axis])
    }

    /// A gesture cut by the end of capture is stopped on the axes it scrolled.
    @Test func captureEndingMidScrollStopsIt() {
        var controller = captured()
        _ = controller.pointer(scroll())
        let release = shiftEsc(&controller)
        #expect(release.messages.contains(.pointerAxis(axis: .vertical, value: 0, discrete: nil, stop: true)))
        #expect(
            !release.messages.contains(.pointerAxis(axis: .horizontal, value: 0, discrete: nil, stop: true)))
        _ = controller.pointer(button(0, true))
        _ = controller.pointer(button(0, false))
        #expect(controller.capture(.windowKey(false)).messages.isEmpty)
    }

    /// Ruling 8: nothing goes until the recapturing button is up, other buttons and scrolling
    /// included.
    @Test func duringTheRecapturingClickNothingElseIsSent() {
        var controller = captured()
        _ = shiftEsc(&controller)
        _ = controller.pointer(button(0, true))
        #expect(controller.pointer(button(1, true)) == InputResult(consumed: true))
        #expect(controller.pointer(scroll()) == InputResult(consumed: true))
        #expect(controller.pointer(button(1, false)) == InputResult(consumed: true))
        #expect(
            controller.pointer(button(0, false))
                == InputResult(consumed: true, messages: [.pointerMotion(x: 0, y: 0)]))
    }

    /// Sleep or a lock keeps capture, but the recapturing click's up may never come.
    @Test func awayForgetsTheRecapturingClick() {
        var controller = captured()
        _ = shiftEsc(&controller)
        _ = controller.pointer(button(1, true))
        _ = controller.capture(.away)
        #expect(controller.pointer(.moved(x: 3, y: 4)).messages == [.pointerMotion(x: 3, y: 4)])
    }

    /// A click takes input back only when it would come back: while the link is interrupted it
    /// passes by, and the release stands once the link returns.
    @Test func aClickThatCantRecaptureLeavesTheReleaseAlone() {
        var controller = captured()
        _ = shiftEsc(&controller)
        _ = controller.capture(.interrupted(true))
        #expect(controller.pointer(button(0, true)) == InputResult())
        #expect(controller.pointer(button(0, false)) == InputResult())
        _ = controller.capture(.interrupted(false))
        #expect(!controller.isCaptured)
    }

    @Test func motionToWhereThePointerIsSendsNothing() {
        var controller = captured()
        #expect(controller.pointer(.moved(x: 0, y: 0)) == InputResult(consumed: true))
        #expect(controller.pointer(scroll()).messages == [axis])
    }

    /// A key can move the remote pointer (a focus binding warps it): the next press moves it
    /// back under the Mac's pointer first.
    @Test func afterAKeyAPressMovesThePointerFirst() {
        var controller = captured()
        _ = controller.key(MacKeyEvent(keyCode: 0x7C, kind: .down(isRepeat: false), flags: 0))
        #expect(controller.pointer(button(0, true)).messages == [.pointerMotion(x: 0, y: 0), left])
    }

    /// Motion may have been dropped while the link was going (the session's gate): once
    /// capture returns, the next press moves the pointer first.
    @Test func afterCaptureReturnsAPressMovesThePointerFirst() {
        var controller = captured()
        _ = controller.capture(.interrupted(true))
        _ = controller.capture(.interrupted(false))
        #expect(controller.pointer(button(0, true)).messages == [.pointerMotion(x: 0, y: 0), left])
    }

    /// A wheel has no gesture to end: release sends no stop for it.
    @Test func aWheelLeavesNoStopOnRelease() {
        var controller = captured()
        let wheel = PointerEvent.scroll(
            ScrollEvent(deltaX: 0, deltaY: 1, isPrecise: false, phase: .none, isMomentum: false), x: 0, y: 0,
            flags: 0)
        _ = controller.pointer(wheel)
        #expect(shiftEsc(&controller).messages.isEmpty)
    }

    /// Shift+Esc during the recapturing click: its up still never reaches the Mac.
    @Test func releaseDuringTheRecapturingClickSwallowsItsUp() {
        var controller = captured()
        _ = shiftEsc(&controller)
        _ = controller.pointer(button(0, true))
        _ = shiftEsc(&controller)
        #expect(controller.pointer(button(0, false)) == InputResult(consumed: true))
        #expect(controller.pointer(button(0, false)) == InputResult())
    }

    /// The recapturing click's up was missed: a fresh press of its button is a click of its own.
    @Test func aFreshPressOfTheRecapturingButtonIsSent() {
        var controller = captured()
        _ = shiftEsc(&controller)
        _ = controller.pointer(button(0, true))
        #expect(controller.pointer(button(0, true)).messages == [.pointerMotion(x: 0, y: 0), left])
    }
}
