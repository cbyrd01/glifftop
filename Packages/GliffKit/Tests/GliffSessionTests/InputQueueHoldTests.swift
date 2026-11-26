import GliffInput
import GliffTestSupport
import Testing

@testable import GliffSession

/// `InputQueue.hold(for:)`: the barrier's wait, on a clock the test moves.
@Suite struct InputQueueHoldTests {
    private let clock = ManualClock()
    private let key = InputMessage.key(code: 30, pressed: true)
    private let release = InputMessage.key(code: 30, pressed: false)

    @Test func aHoldKeepsEverythingInOrder() async {
        let queue = InputQueue(clock: clock)
        queue.hold(for: .milliseconds(30))
        queue.append(key)
        queue.append(.clipboard(.revoke(sendEmpty: false)))
        queue.append(release)
        #expect(queue.take().inputs.isEmpty)
        #expect(await clock.waitForSleepers(1))
        clock.advance(by: .milliseconds(30))
        let (inputs, command) = queue.take()
        #expect(inputs == [key])
        #expect(command == .revoke(sendEmpty: false))
        #expect(queue.take().inputs == [release])
    }

    @Test func theEndOfAHoldWakesTheDrain() async {
        let queue = InputQueue(clock: clock)
        queue.hold(for: .milliseconds(30))
        var wakeups = queue.wakeups.makeAsyncIterator()
        queue.append(key)
        await wakeups.next()
        #expect(queue.take().inputs.isEmpty)
        #expect(await clock.waitForSleepers(1))
        clock.advance(by: .milliseconds(30))
        await wakeups.next()
        #expect(queue.take().inputs == [key])
    }

    /// Two holds, either way round: the longer one keeps the queue.
    @Test(arguments: [(10, 30), (30, 10)]) func theLongerHoldWins(_ first: Int, _ second: Int) async {
        let queue = InputQueue(clock: clock)
        queue.hold(for: .milliseconds(first))
        queue.hold(for: .milliseconds(second))
        queue.append(key)
        #expect(await clock.waitForSleepers(1))
        clock.advance(by: .milliseconds(10))
        #expect(queue.take().inputs.isEmpty)
        clock.advance(by: .milliseconds(20))
        #expect(queue.take().inputs == [key])
    }

    /// Holds that end at the same time, or sooner, keep the one timer.
    @Test func aHoldNoLongerStartsNoTimer() async {
        let queue = InputQueue(clock: clock)
        queue.hold(for: .milliseconds(30))
        #expect(await clock.waitForSleepers(1))
        queue.hold(for: .milliseconds(20))
        queue.hold(for: .milliseconds(30))
        #expect(queue.timersStarted == 1)
    }

    /// A longer hold moves the end; the timer sleeps on to it.
    @Test func aLongerHoldKeepsTheTimer() async {
        let queue = InputQueue(clock: clock)
        var wakeups = queue.wakeups.makeAsyncIterator()
        queue.hold(for: .milliseconds(10))
        queue.hold(for: .milliseconds(30))
        queue.append(key)
        await wakeups.next()
        #expect(await clock.waitForSleepers(1))
        clock.advance(by: .milliseconds(10))
        #expect(await clock.waitForSleepers(1))
        clock.advance(by: .milliseconds(20))
        await wakeups.next()
        #expect(queue.take().inputs == [key])
        #expect(queue.timersStarted == 1)
    }

    /// A pause lets what came before it go, and holds what follows from when that goes.
    @Test func aPauseHoldsWhatFollowsFromWhenItIsReached() async {
        let queue = InputQueue(clock: clock)
        let motion = InputMessage.pointerMotion(x: 1, y: 2)
        queue.append(motion)
        queue.append(.pause(.milliseconds(50)))
        queue.append(key)
        clock.advance(by: .milliseconds(80))
        #expect(queue.take().inputs == [motion])
        #expect(queue.take().inputs.isEmpty)
        #expect(await clock.waitForSleepers(1))
        clock.advance(by: .milliseconds(50))
        #expect(queue.take().inputs == [key])
    }

    /// A pause behind a hold starts once the hold has let what came before it go.
    @Test func aPauseBehindAHoldStartsAfterIt() async {
        let queue = InputQueue(clock: clock)
        let motion = InputMessage.pointerMotion(x: 1, y: 2)
        queue.hold(for: .milliseconds(30))
        queue.append(motion)
        queue.append(.pause(.milliseconds(50)))
        queue.append(key)
        #expect(await clock.waitForSleepers(1))
        clock.advance(by: .milliseconds(30))
        #expect(queue.take().inputs == [motion])
        clock.advance(by: .milliseconds(30))
        #expect(queue.take().inputs.isEmpty)
        clock.advance(by: .milliseconds(20))
        #expect(queue.take().inputs == [key])
    }

    /// How long what is appended now waits: until the hold's end or the barrier's wait,
    /// whichever is later, then every pause still queued.
    @Test func theDelayCountsTheHoldAndThePausesQueued() {
        let queue = InputQueue(clock: clock)
        #expect(queue.delay(holding: .milliseconds(5)) == .milliseconds(5))
        queue.hold(for: .milliseconds(30))
        queue.append(.pause(.milliseconds(50)))
        #expect(queue.delay(holding: .zero) == .milliseconds(80))
        #expect(queue.delay(holding: .milliseconds(40)) == .milliseconds(90))
        clock.advance(by: .milliseconds(30))
        _ = queue.take()
        #expect(queue.delay(holding: .zero) == .milliseconds(50))
    }

    @Test func takeAllIgnoresAPause() {
        let queue = InputQueue(clock: clock)
        queue.append(.pause(.milliseconds(50)))
        queue.append(key)
        #expect(queue.takeAll() == [key])
    }

    /// Judging what is held: inputs kept or dropped in place, a clipboard command kept.
    @Test func heldInputCanBeJudged() {
        let queue = InputQueue(clock: clock)
        queue.hold(for: .milliseconds(30))
        queue.append(key)
        queue.append(.keymap("k"))
        queue.append(.clipboard(.revoke(sendEmpty: false)))
        queue.append(release)
        queue.keepInputs { $0 != key }
        #expect(queue.takeAll() == [.keymap("k"), release])
    }

    /// The judge sees each input once, in order (clipboard commands never), so it can judge each
    /// after the ones before it.
    @Test func eachInputIsJudgedOnceInOrder() {
        let queue = InputQueue(clock: clock)
        queue.hold(for: .milliseconds(30))
        queue.append(key)
        queue.append(.clipboard(.revoke(sendEmpty: false)))
        queue.append(release)
        var seen: [InputMessage] = []
        queue.keepInputs {
            seen.append($0)
            return true
        }
        #expect(seen == [key, release])
    }

    @Test func takeAllIgnoresAHold() {
        let queue = InputQueue(clock: clock)
        queue.hold(for: .milliseconds(30))
        queue.append(key)
        #expect(queue.takeAll() == [key])
    }

    @Test func closeDropsWhatIsHeld() async {
        let queue = InputQueue(clock: clock)
        queue.hold(for: .milliseconds(30))
        queue.append(key)
        queue.close()
        #expect(await clock.waitForSleepers(0))
        clock.advance(by: .milliseconds(30))
        #expect(queue.takeAll().isEmpty)
        // The append's wakeup, then the end: the hold's timer was cancelled.
        var wakeups = 0
        for await _ in queue.wakeups { wakeups += 1 }
        #expect(wakeups <= 1)
    }
}
