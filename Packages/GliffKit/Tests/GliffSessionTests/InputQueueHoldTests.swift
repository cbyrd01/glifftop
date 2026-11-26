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
        #expect(queue.takeUntilClipboard().inputs.isEmpty)
        #expect(await clock.waitForSleepers(1))
        clock.advance(by: .milliseconds(30))
        let (inputs, command) = queue.takeUntilClipboard()
        #expect(inputs == [key])
        #expect(command == .revoke(sendEmpty: false))
        #expect(queue.takeUntilClipboard().inputs == [release])
    }

    @Test func theEndOfAHoldWakesTheDrain() async {
        let queue = InputQueue(clock: clock)
        queue.hold(for: .milliseconds(30))
        var wakeups = queue.wakeups.makeAsyncIterator()
        queue.append(key)
        await wakeups.next()
        #expect(queue.takeUntilClipboard().inputs.isEmpty)
        #expect(await clock.waitForSleepers(1))
        clock.advance(by: .milliseconds(30))
        await wakeups.next()
        #expect(queue.takeUntilClipboard().inputs == [key])
    }

    /// Two holds, either way round: the longer one keeps the queue.
    @Test(arguments: [(10, 30), (30, 10)]) func theLongerHoldWins(_ first: Int, _ second: Int) async {
        let queue = InputQueue(clock: clock)
        queue.hold(for: .milliseconds(first))
        queue.hold(for: .milliseconds(second))
        queue.append(key)
        #expect(await clock.waitForSleepers(1))
        clock.advance(by: .milliseconds(10))
        #expect(queue.takeUntilClipboard().inputs.isEmpty)
        clock.advance(by: .milliseconds(20))
        #expect(queue.takeUntilClipboard().inputs == [key])
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
        #expect(queue.takeUntilClipboard().inputs == [key])
        #expect(queue.timersStarted == 1)
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
