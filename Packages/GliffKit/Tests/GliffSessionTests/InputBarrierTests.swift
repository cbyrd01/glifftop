import GliffInput
import GliffProtocol
import GliffTestSupport
import Testing

@testable import GliffSession

@Suite struct InputBarrierTests {
    /// Two sessions.
    private let a = InputBarrier.Sender()
    private let b = InputBarrier.Sender()
    private let clock = ManualClock()
    private let barrier: InputBarrier
    /// Super's release, and a key's press.
    private let superUp = InputMessage.key(code: 125, pressed: false)
    private let press = InputMessage.key(code: 3, pressed: true)

    init() { barrier = InputBarrier(clock: clock) }

    static let kinds: [InputMessage] = [
        .pointerMotion(x: 1, y: 2),
        .pointerButton(code: 272, pressed: true),
        .pointerAxis(axis: .vertical, value: 1, discrete: 1, stop: false),
        .keymap("xkb"),
    ]

    /// Each sender is new, never one that has gone.
    @Test func sendersAreUnique() {
        #expect(Set((0..<100).map { _ in InputBarrier.Sender() }).count == 100)
    }

    @Test func anotherSessionWaitsAfterAModifierRelease() {
        #expect(barrier.wait(before: superUp, from: a) == nil)
        #expect(barrier.wait(before: press, from: b) == .milliseconds(30))
    }

    @Test func theWaitShrinksWithTime() {
        _ = barrier.wait(before: superUp, from: a)
        clock.advance(by: .milliseconds(10))
        #expect(barrier.wait(before: press, from: b) == .milliseconds(20))
    }

    @Test func nothingWaitsAtThirtyMilliseconds() {
        _ = barrier.wait(before: superUp, from: a)
        clock.advance(by: .milliseconds(30))
        #expect(barrier.wait(before: press, from: b) == nil)
    }

    @Test func theSameSessionNeverWaits() {
        _ = barrier.wait(before: superUp, from: a)
        #expect(barrier.wait(before: press, from: a) == nil)
    }

    @Test func aPlainReleaseSetsNoBarrier() {
        _ = barrier.wait(before: .key(code: 30, pressed: false), from: a)
        #expect(barrier.wait(before: press, from: b) == nil)
    }

    @Test func aPressOrAButtonSetsNoBarrier() {
        _ = barrier.wait(before: .key(code: 125, pressed: true), from: a)
        _ = barrier.wait(before: .pointerButton(code: 272, pressed: false), from: a)
        _ = barrier.wait(before: .pointerAxis(axis: .vertical, value: 0, discrete: nil, stop: true), from: a)
        #expect(barrier.wait(before: press, from: b) == nil)
    }

    @Test(arguments: InputBarrierTests.kinds) func everyKindWaits(_ input: InputMessage) {
        _ = barrier.wait(before: superUp, from: a)
        #expect(barrier.wait(before: input, from: b) == .milliseconds(30))
    }

    /// A release that waits goes later, and the barrier counts from then.
    @Test func aHeldReleaseCountsFromWhenItGoes() {
        _ = barrier.wait(before: superUp, from: b)
        clock.advance(by: .milliseconds(10))
        #expect(barrier.wait(before: .key(code: 42, pressed: false), from: a) == .milliseconds(20))
        #expect(barrier.wait(before: press, from: b) == .milliseconds(50))
    }

    /// A session's next release goes after its held one, so the barrier never moves earlier.
    @Test func aLaterReleaseBehindAHoldCountsFromTheHold() {
        _ = barrier.wait(before: superUp, from: b)
        _ = barrier.wait(before: .key(code: 42, pressed: false), from: a)
        clock.advance(by: .milliseconds(10))
        #expect(barrier.wait(before: .key(code: 29, pressed: false), from: a) == nil)
        #expect(barrier.wait(before: press, from: b) == .milliseconds(50))
    }

    /// A release its own queue holds (an activation's pause) goes when that hold lets it: the
    /// barrier counts from then.
    @Test func aReleaseItsOwnQueueHoldsCountsFromWhenItGoes() {
        _ = barrier.wait(before: superUp, from: a, goesAfter: { $0 + .milliseconds(50) })
        #expect(barrier.wait(before: press, from: b) == .milliseconds(80))
    }
}
