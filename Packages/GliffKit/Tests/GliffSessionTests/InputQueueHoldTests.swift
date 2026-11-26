import GliffInput
import GliffTestSupport
import Testing

@testable import GliffSession

/// `InputQueue.holdWhatFollows(for:)`: the barrier's wait, on a clock the test moves.
@Suite struct InputQueueHoldTests {
    private let clock = ManualClock()
    private let key = InputMessage.key(code: 30, pressed: true)
    private let release = InputMessage.key(code: 30, pressed: false)

    @Test func aHoldKeepsEverythingInOrder() async {
        let queue = InputQueue(clock: clock)
        queue.holdWhatFollows(for: .milliseconds(30))
        queue.append(key)
        queue.append(.clipboard(.revoke(sendEmpty: false)))
        queue.append(release)
        #expect(queue.take().inputs.isEmpty)
        #expect(await clock.waitForSleepers(1))
        clock.advance(by: .milliseconds(30))
        let taken = queue.take()
        #expect(taken.inputs == [key])
        #expect(taken.command == .revoke(sendEmpty: false))
        #expect(queue.take().inputs == [release])
    }

    /// What was queued before a hold goes as it would: the hold keeps only what follows it.
    @Test func aHoldKeepsOnlyWhatFollowsIt() async {
        let queue = InputQueue(clock: clock)
        queue.append(key)
        queue.holdWhatFollows(for: .milliseconds(30))
        queue.append(release)
        #expect(queue.take().inputs == [key])
        #expect(queue.take().inputs.isEmpty)
        #expect(await clock.waitForSleepers(1))
        clock.advance(by: .milliseconds(30))
        #expect(queue.take().inputs == [release])
    }

    @Test func theEndOfAHoldWakesTheDrain() async {
        let queue = InputQueue(clock: clock)
        queue.holdWhatFollows(for: .milliseconds(30))
        var wakeups = queue.wakeups.makeAsyncIterator()
        queue.append(key)
        await wakeups.next()
        #expect(queue.take().inputs.isEmpty)
        #expect(await clock.waitForSleepers(1))
        clock.advance(by: .milliseconds(30))
        await wakeups.next()
        #expect(queue.take().inputs == [key])
    }

    /// Two holds, either way round: the longer one keeps what follows both.
    @Test(arguments: [(10, 30), (30, 10)]) func theLongerHoldWins(_ first: Int, _ second: Int) async {
        let queue = InputQueue(clock: clock)
        queue.holdWhatFollows(for: .milliseconds(first))
        queue.holdWhatFollows(for: .milliseconds(second))
        queue.append(key)
        #expect(queue.take().inputs.isEmpty)
        #expect(await clock.waitForSleepers(1))
        clock.advance(by: .milliseconds(10))
        #expect(queue.take().inputs.isEmpty)
        clock.advance(by: .milliseconds(20))
        #expect(queue.take().inputs == [key])
    }

    /// A hold for another session's release ends `left` after its answer, if that is sooner.
    @Test func anAnswerEndsTheHoldSooner() async {
        let queue = InputQueue(clock: clock)
        let release = Self.release()
        queue.holdWhatFollows(for: .milliseconds(250), awaiting: release)
        queue.append(key)
        #expect(queue.take().inputs.isEmpty)
        #expect(await clock.waitForSleepers(1))
        clock.advance(by: .milliseconds(4))
        queue.answered(release, left: .milliseconds(10))
        // The old timer's sleep is cancelled; the new one sleeps until the new end.
        #expect(await clock.waitForSleepers(1))
        clock.advance(by: .milliseconds(9))
        #expect(queue.take().inputs.isEmpty)
        clock.advance(by: .milliseconds(1))
        #expect(queue.take().inputs == [key])
    }

    /// The end of a hold an answer shortened wakes the drain.
    @Test func theEndOfAnAnsweredHoldWakesTheDrain() async {
        let queue = InputQueue(clock: clock)
        let release = Self.release()
        queue.holdWhatFollows(for: .milliseconds(250), awaiting: release)
        var wakeups = queue.wakeups.makeAsyncIterator()
        queue.append(key)
        await wakeups.next()
        #expect(queue.take().inputs.isEmpty)
        #expect(await clock.waitForSleepers(1))
        queue.answered(release, left: .zero)
        await wakeups.next()
        #expect(queue.take().inputs == [key])
    }

    /// A hold not yet reached is shortened too: it ends no later than its answer says.
    @Test func anAnswerShortensAHoldStillQueued() async {
        let queue = InputQueue(clock: clock)
        let release = Self.release()
        queue.append(.pause(.milliseconds(50)))
        queue.holdWhatFollows(for: .milliseconds(250), awaiting: release)
        queue.append(key)
        #expect(queue.take().inputs.isEmpty)
        queue.answered(release, left: .milliseconds(10))
        #expect(await clock.waitForSleepers(1))
        clock.advance(by: .milliseconds(50))
        #expect(queue.take().inputs == [key])
    }

    /// Another release's answer leaves the hold as it was.
    @Test func anotherReleasesAnswerChangesNothing() async {
        let queue = InputQueue(clock: clock)
        queue.holdWhatFollows(for: .milliseconds(250), awaiting: Self.release())
        queue.append(key)
        #expect(queue.take().inputs.isEmpty)
        #expect(await clock.waitForSleepers(1))
        queue.answered(Self.release(), left: .zero)
        clock.advance(by: .milliseconds(249))
        #expect(queue.take().inputs.isEmpty)
        clock.advance(by: .milliseconds(1))
        #expect(queue.take().inputs == [key])
    }

    /// Each input sent while one release is unanswered waits for it, but one hold keeps them
    /// all: a hold for a release already held for, queued or reached, is not queued again.
    @Test func oneReleaseIsHeldForOnce() {
        let queue = InputQueue(clock: clock)
        let release = Self.release()
        #expect(queue.holdWhatFollows(for: .milliseconds(250), awaiting: release))
        queue.append(key)
        #expect(!queue.holdWhatFollows(for: .milliseconds(250), awaiting: release))
        #expect(queue.take().inputs.isEmpty)
        #expect(!queue.holdWhatFollows(for: .milliseconds(250), awaiting: release))
        #expect(queue.holdWhatFollows(for: .milliseconds(250), awaiting: Self.release()))
        #expect(queue.holdWhatFollows(for: .milliseconds(250)))
    }

    /// A fence goes with the input around it, as one of the fences taken.
    @Test func fencesAreTakenWithTheInput() {
        let queue = InputQueue(clock: clock)
        let release = Self.release()
        queue.append(key)
        queue.append(.fence(release))
        queue.append(self.release)
        let taken = queue.take()
        #expect(taken.inputs == [key, self.release])
        #expect(taken.fences == [release])
        #expect(queue.take() == .init())
    }

    private static func release() -> InputBarrier.Release {
        InputBarrier.Release(sender: InputBarrier.Sender(), number: 1)
    }

    /// A hold starts its timer once reached; holds behind it that end no later start none.
    @Test func aHoldNoLongerStartsNoTimer() async {
        let queue = InputQueue(clock: clock)
        queue.holdWhatFollows(for: .milliseconds(30))
        queue.holdWhatFollows(for: .milliseconds(20))
        queue.holdWhatFollows(for: .milliseconds(30))
        queue.append(key)
        #expect(queue.timersStarted == 0)
        #expect(queue.take().inputs.isEmpty)
        #expect(await clock.waitForSleepers(1))
        clock.advance(by: .milliseconds(30))
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
        queue.holdWhatFollows(for: .milliseconds(30))
        queue.append(motion)
        queue.append(.pause(.milliseconds(50)))
        queue.append(key)
        #expect(queue.take().inputs.isEmpty)
        #expect(await clock.waitForSleepers(1))
        clock.advance(by: .milliseconds(30))
        #expect(queue.take().inputs == [motion])
        clock.advance(by: .milliseconds(30))
        #expect(queue.take().inputs.isEmpty)
        clock.advance(by: .milliseconds(20))
        #expect(queue.take().inputs == [key])
    }

    /// How long what is appended now waits: until what is queued before it has gone, its holds
    /// and pauses in turn, or the barrier's wait, whichever is later.
    @Test func theDelayCountsTheHoldAndThePausesQueued() {
        let queue = InputQueue(clock: clock)
        #expect(queue.delay(holding: .milliseconds(5)) == .milliseconds(5))
        queue.holdWhatFollows(for: .milliseconds(30))
        queue.append(.pause(.milliseconds(50)))
        #expect(queue.delay(holding: .zero) == .milliseconds(80))
        #expect(queue.delay(holding: .milliseconds(40)) == .milliseconds(80))
        #expect(queue.delay(holding: .milliseconds(90)) == .milliseconds(90))
        clock.advance(by: .milliseconds(30))
        _ = queue.take()
        #expect(queue.delay(holding: .zero) == .milliseconds(50))
    }

    @Test func takeAllIgnoresAPause() {
        let queue = InputQueue(clock: clock)
        queue.append(.pause(.milliseconds(50)))
        queue.append(key)
        #expect(queue.takeAll().inputs == [key])
    }

    /// Judging what is held: inputs kept or dropped in place, a clipboard command kept.
    @Test func heldInputCanBeJudged() {
        let queue = InputQueue(clock: clock)
        queue.holdWhatFollows(for: .milliseconds(30))
        queue.append(key)
        queue.append(.keymap("k"))
        queue.append(.clipboard(.revoke(sendEmpty: false)))
        queue.append(release)
        queue.keepInputs { $0 != key }
        #expect(queue.takeAll().inputs == [.keymap("k"), release])
    }

    /// The judge sees each input once, in order (clipboard commands never), so it can judge each
    /// after the ones before it.
    @Test func eachInputIsJudgedOnceInOrder() {
        let queue = InputQueue(clock: clock)
        queue.holdWhatFollows(for: .milliseconds(30))
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
        queue.holdWhatFollows(for: .milliseconds(30))
        queue.append(key)
        #expect(queue.takeAll().inputs == [key])
    }

    @Test func closeDropsWhatIsHeld() async {
        let queue = InputQueue(clock: clock)
        queue.holdWhatFollows(for: .milliseconds(30))
        queue.append(key)
        queue.close()
        #expect(await clock.waitForSleepers(0))
        clock.advance(by: .milliseconds(30))
        #expect(queue.takeAll().inputs.isEmpty)
        // The append's wakeup, then the end: the hold's timer was cancelled.
        var wakeups = 0
        for await _ in queue.wakeups { wakeups += 1 }
        #expect(wakeups <= 1)
    }
}
