import GliffInput
import GliffProtocol
import GliffTestSupport
import Synchronization
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

    /// A modifier release is recorded, for its session to ask its server to answer behind it.
    @Test func aModifierReleaseIsRecorded() {
        let release = barrier.wait(before: superUp, from: a).recorded
        #expect(release?.sender == a)
        #expect(barrier.wait(before: superUp, from: a).recorded != release)
    }

    /// Until its server answers, another session's input waits for it, at most `limit`.
    @Test func anotherSessionWaitsForTheAnswerAtMostTheLimit() {
        let release = barrier.wait(before: superUp, from: a).recorded
        let wait = barrier.wait(before: press, from: b).wait
        #expect(wait?.release == release)
        #expect(wait?.left == InputBarrier.limit)
    }

    @Test func theLimitShrinksWithTime() {
        _ = barrier.wait(before: superUp, from: a)
        clock.advance(by: .milliseconds(10))
        #expect(barrier.wait(before: press, from: b).wait?.left == InputBarrier.limit - .milliseconds(10))
    }

    @Test func nothingWaitsPastTheLimit() {
        _ = barrier.wait(before: superUp, from: a)
        clock.advance(by: InputBarrier.limit)
        #expect(barrier.wait(before: press, from: b).wait == nil)
    }

    /// Once answered, another session's input waits only `settle` from the answer.
    @Test func theAnswerLeavesOnlyTheSettle() throws {
        let release = try #require(barrier.wait(before: superUp, from: a).recorded)
        clock.advance(by: .milliseconds(4))
        barrier.answered(release)
        clock.advance(by: .milliseconds(3))
        #expect(barrier.wait(before: press, from: b).wait?.left == InputBarrier.settle - .milliseconds(3))
        clock.advance(by: InputBarrier.settle)
        #expect(barrier.wait(before: press, from: b).wait == nil)
    }

    /// An earlier release's answer doesn't answer a later one.
    @Test func anEarlierAnswerLeavesALaterReleaseWaiting() throws {
        let first = try #require(barrier.wait(before: superUp, from: a).recorded)
        _ = barrier.wait(before: .key(code: 42, pressed: false), from: a)
        barrier.answered(first)
        #expect(barrier.wait(before: press, from: b).wait?.left == InputBarrier.limit)
    }

    /// The waiter learns of the answer when it comes: what it has left, the settle.
    @Test func aWaiterHearsTheAnswer() throws {
        let release = try #require(barrier.wait(before: superUp, from: a).recorded)
        let heard = Mutex<[Duration]>([])
        barrier.whenAnswered(release) { left in heard.withLock { $0.append(left) } }
        #expect(heard.withLock { $0 }.isEmpty)
        barrier.answered(release)
        barrier.answered(release)
        #expect(heard.withLock { $0 } == [InputBarrier.settle])
    }

    /// A waiter asking after the answer hears at once, with what is left of the settle.
    @Test func aWaiterAfterTheAnswerHearsAtOnce() throws {
        let release = try #require(barrier.wait(before: superUp, from: a).recorded)
        barrier.answered(release)
        clock.advance(by: .milliseconds(4))
        let heard = Mutex<[Duration]>([])
        barrier.whenAnswered(release) { left in heard.withLock { $0.append(left) } }
        #expect(heard.withLock { $0 } == [InputBarrier.settle - .milliseconds(4)])
    }

    @Test func theSameSessionNeverWaits() {
        _ = barrier.wait(before: superUp, from: a)
        #expect(barrier.wait(before: press, from: a).wait == nil)
    }

    @Test func aPlainReleaseSetsNoBarrier() {
        #expect(barrier.wait(before: .key(code: 30, pressed: false), from: a).recorded == nil)
        #expect(barrier.wait(before: press, from: b).wait == nil)
    }

    @Test func aPressOrAButtonSetsNoBarrier() {
        _ = barrier.wait(before: .key(code: 125, pressed: true), from: a)
        _ = barrier.wait(before: .pointerButton(code: 272, pressed: false), from: a)
        _ = barrier.wait(before: .pointerAxis(axis: .vertical, value: 0, discrete: nil, stop: true), from: a)
        #expect(barrier.wait(before: press, from: b).wait == nil)
    }

    @Test(arguments: InputBarrierTests.kinds) func everyKindWaits(_ input: InputMessage) {
        _ = barrier.wait(before: superUp, from: a)
        #expect(barrier.wait(before: input, from: b).wait?.left == InputBarrier.limit)
    }

    /// A release that waits goes later, and its limit counts from then.
    @Test func aHeldReleaseCountsFromWhenItGoes() {
        _ = barrier.wait(before: superUp, from: b)
        clock.advance(by: .milliseconds(10))
        let left = InputBarrier.limit - .milliseconds(10)
        #expect(barrier.wait(before: .key(code: 42, pressed: false), from: a).wait?.left == left)
        #expect(barrier.wait(before: press, from: b).wait?.left == left + InputBarrier.limit)
    }

    /// A session's next release goes after its held one, so its limit never moves earlier.
    @Test func aLaterReleaseBehindAHoldCountsFromTheHold() {
        _ = barrier.wait(before: superUp, from: b)
        _ = barrier.wait(before: .key(code: 42, pressed: false), from: a)
        clock.advance(by: .milliseconds(10))
        #expect(barrier.wait(before: .key(code: 29, pressed: false), from: a).wait == nil)
        #expect(barrier.wait(before: press, from: b).wait?.left == InputBarrier.limit * 2 - .milliseconds(10))
    }

    /// A release its own queue holds (an activation's pause) goes when that hold lets it: its
    /// limit counts from then.
    @Test func aReleaseItsOwnQueueHoldsCountsFromWhenItGoes() {
        _ = barrier.wait(before: superUp, from: a, goesAfter: { $0 + .milliseconds(50) })
        #expect(barrier.wait(before: press, from: b).wait?.left == .milliseconds(50) + InputBarrier.limit)
    }
}
