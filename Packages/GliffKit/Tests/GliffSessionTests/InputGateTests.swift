import GliffInput
import GliffProtocol
import Testing

@testable import GliffSession

/// Which input reaches the server: a press only to a live stream; a release only for a press
/// that went (and then always, so a key held across an interruption is let go when the link
/// returns, and the remote never sees a release it can't pair); keymaps always.
@Suite struct InputGateTests {
    private let press = InputMessage.key(code: 30, pressed: true)
    private let release = InputMessage.key(code: 30, pressed: false)

    @Test func pressesNeedALiveStream() {
        var gate = InputGate()
        let admitted1 = gate.admits(press, streaming: false, interrupted: false)
        #expect(!admitted1)
        let admitted2 = gate.admits(press, streaming: true, interrupted: true)
        #expect(!admitted2)
        let admitted3 = gate.admits(press, streaming: true, interrupted: false)
        #expect(admitted3)
    }

    @Test func aSentPressIsReleasedEvenWhileInterrupted() {
        var gate = InputGate()
        _ = gate.admits(press, streaming: true, interrupted: false)
        let admitted4 = gate.admits(release, streaming: false, interrupted: true)
        #expect(admitted4)
        let admitted5 = gate.admits(release, streaming: true, interrupted: false)
        #expect(!admitted5)
    }

    @Test func aDroppedPressDropsItsRelease() {
        var gate = InputGate()
        _ = gate.admits(press, streaming: true, interrupted: true)
        let admitted6 = gate.admits(release, streaming: true, interrupted: false)
        #expect(!admitted6)
    }

    @Test func keymapsAlwaysPass() {
        var gate = InputGate()
        let admitted7 = gate.admits(.keymap("k"), streaming: false, interrupted: true)
        #expect(admitted7)
    }

    @Test func pointerInputOnlyToALiveStream() {
        let inputs: [InputMessage] = [
            .pointerMotion(x: 1, y: 2), .pointerAxis(axis: .vertical, value: 3, discrete: nil, stop: false),
            .pointerButton(code: 0x110, pressed: true),
        ]
        for input in inputs {
            var gate = InputGate()
            let notStreaming = gate.admits(input, streaming: false, interrupted: false)
            let interrupted = gate.admits(input, streaming: true, interrupted: true)
            let live = gate.admits(input, streaming: true, interrupted: false)
            #expect(!notStreaming && !interrupted && live, "\(input)")
        }
    }

    @Test func aButtonReleaseGoesOnlyForAPressThatWent() {
        var gate = InputGate()
        let unpaired = gate.admits(
            .pointerButton(code: 0x110, pressed: false), streaming: true, interrupted: false)
        #expect(!unpaired)
        _ = gate.admits(.pointerButton(code: 0x110, pressed: true), streaming: true, interrupted: false)
        let paired = gate.admits(
            .pointerButton(code: 0x110, pressed: false), streaming: false, interrupted: true)
        #expect(paired)
    }

    /// A gesture's stop ends what went, like a release: it goes even while interrupted, once
    /// its axis has scrolled, and only then.
    @Test func aScrollStopGoesOnceItsAxisScrolled() {
        var gate = InputGate()
        let stop = InputMessage.pointerAxis(axis: .vertical, value: 0, discrete: nil, stop: true)
        let early = gate.admits(stop, streaming: true, interrupted: false)
        #expect(!early)
        _ = gate.admits(
            .pointerAxis(axis: .vertical, value: 4, discrete: nil, stop: false), streaming: true,
            interrupted: false)
        let horizontal = gate.admits(
            .pointerAxis(axis: .horizontal, value: 0, discrete: nil, stop: true), streaming: true,
            interrupted: true)
        #expect(!horizontal)
        let ended = gate.admits(stop, streaming: false, interrupted: true)
        #expect(ended)
        let again = gate.admits(stop, streaming: true, interrupted: false)
        #expect(!again)
    }

    /// A wheel's steps never end with a stop: only a precise scroll opens an axis for one, so a
    /// gesture's stops on both axes don't stop an axis only a wheel turned.
    @Test func aWheelDoesNotOpenAnAxisForAStop() {
        var gate = InputGate()
        _ = gate.admits(
            .pointerAxis(axis: .vertical, value: 15, discrete: 1, stop: false), streaming: true,
            interrupted: false)
        let stop = gate.admits(
            .pointerAxis(axis: .vertical, value: 0, discrete: nil, stop: true), streaming: true,
            interrupted: false)
        #expect(!stop)
    }

    @Test func keysAndButtonsAreTrackedApart() {
        var gate = InputGate()
        _ = gate.admits(.key(code: 30, pressed: true), streaming: true, interrupted: false)
        let button = gate.admits(
            .pointerButton(code: 30, pressed: false), streaming: true, interrupted: false)
        #expect(!button)
        _ = gate.admits(.pointerButton(code: 0x110, pressed: true), streaming: true, interrupted: false)
        let key = gate.admits(.key(code: 0x110, pressed: false), streaming: true, interrupted: false)
        #expect(!key)
    }
}
