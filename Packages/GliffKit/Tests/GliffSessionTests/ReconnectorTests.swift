import GliffTestSupport
import GliffTransport
import Synchronization
import Testing

@testable import GliffSession

/// Trying again after a session ends: a countdown per try, on a clock the test moves, that the
/// person can cut short, that waits while the Mac is offline, and that a Disconnect cancels.
@Suite(.timeLimit(.minutes(1))) struct ReconnectorTests {
    /// What each try does, in order: an outcome, or hang until cancelled. Past the end, hang.
    final class Script: Sendable {
        enum Step: Sendable {
            case outcome(ReconnectAttempt)
            /// Waits for the cancel, then returns this (a try that streamed as Disconnect came).
            case onCancel(ReconnectAttempt)
            case hang
        }

        private let steps: Mutex<[Step]>
        private let calls = Mutex(0)

        init(_ steps: [Step]) { self.steps = Mutex(steps) }

        var callCount: Int { calls.withLock { $0 } }

        private static func untilCancelled() async {
            let (stream, continuation) = AsyncStream<Never>.makeStream()
            await withTaskCancellationHandler {
                for await _ in stream {}
            } onCancel: {
                continuation.finish()
            }
        }

        @Sendable func next() async -> ReconnectAttempt {
            calls.withLock { $0 += 1 }
            let step = steps.withLock { $0.isEmpty ? .hang : $0.removeFirst() }
            switch step {
            case .outcome(let outcome):
                return outcome
            case .onCancel(let outcome):
                await Self.untilCancelled()
                return outcome
            case .hang:
                await Self.untilCancelled()
                return .ended(.disconnected)
            }
        }
    }

    let clock = ManualClock()

    /// Reads each state; at a wait, lets the clock run it out.
    func follow(
        _ states: inout AsyncStream<ReconnectState>.Iterator, count: Int
    ) async -> [ReconnectState] {
        var seen: [ReconnectState] = []
        for _ in 0..<count {
            guard let state = await states.next(isolation: #isolation) else { break }
            seen.append(state)
            if case .waiting(_, let delay) = state {
                _ = await clock.waitForSleepers(1)
                clock.advance(by: delay)
            }
        }
        return seen
    }

    @Test func retriesUntilASessionStreams() async {
        let script = Script([.outcome(.ended(.connectionLost)), .outcome(.streaming)])
        let reconnector = Reconnector(clock: clock, attempt: script.next)
        var states = reconnector.states.makeAsyncIterator()
        let run = Task { await reconnector.run(after: .connectionLost) }
        let seen = await follow(&states, count: 4)
        #expect(
            seen == [
                .waiting(attempt: 1, delay: .seconds(1)), .trying(attempt: 1),
                .waiting(attempt: 2, delay: .seconds(2)), .trying(attempt: 2),
            ])
        #expect(await run.value == .reconnected)
        #expect(clock.now.offset == .seconds(3))
    }

    @Test func givesUpAfterFiveTries() async {
        let script = Script(Array(repeating: .outcome(.ended(.connectionLost)), count: 5))
        let reconnector = Reconnector(clock: clock, attempt: script.next)
        var states = reconnector.states.makeAsyncIterator()
        let run = Task { await reconnector.run(after: .connectionLost) }
        let seen = await follow(&states, count: 10)
        #expect(seen.last == .trying(attempt: 5))
        #expect(await run.value == .gaveUp(.connectionLost))
        #expect(script.callCount == 5)
    }

    @Test func aRefusedSignInGivesUpAtOnce() async {
        let script = Script([
            .outcome(.ended(.connectionLost)), .outcome(.ended(.connectFailed(.permissionDenied))),
        ])
        let reconnector = Reconnector(clock: clock, attempt: script.next)
        var states = reconnector.states.makeAsyncIterator()
        let run = Task { await reconnector.run(after: .connectionLost) }
        _ = await follow(&states, count: 4)
        #expect(await run.value == .gaveUp(.connectFailed(.permissionDenied)))
        #expect(script.callCount == 2)
    }

    @Test func anEndThatMayNotReconnectGivesUpWithoutATry() async {
        let script = Script([])
        let reconnector = Reconnector(clock: clock, attempt: script.next)
        #expect(await reconnector.run(after: .disconnected) == .gaveUp(.disconnected))
        #expect(script.callCount == 0)
    }

    @Test func reconnectNowSkipsTheWait() async {
        let script = Script([.outcome(.streaming)])
        let reconnector = Reconnector(clock: clock, attempt: script.next)
        var states = reconnector.states.makeAsyncIterator()
        let run = Task { await reconnector.run(after: .connectionLost) }
        #expect(await states.next(isolation: #isolation) == .waiting(attempt: 1, delay: .seconds(1)))
        await reconnector.reconnectNow()
        #expect(await states.next(isolation: #isolation) == .trying(attempt: 1))
        #expect(await run.value == .reconnected)
        #expect(clock.now.offset == .zero)
    }

    /// Offline stops the countdown; back online, it starts again, so a network that keeps
    /// dropping can't spend the tries in a burst.
    @Test func offlinePausesTheCountdown() async {
        let script = Script([.outcome(.streaming)])
        let reconnector = Reconnector(clock: clock, attempt: script.next)
        var states = reconnector.states.makeAsyncIterator()
        let run = Task { await reconnector.run(after: .connectionLost) }
        #expect(await states.next(isolation: #isolation) == .waiting(attempt: 1, delay: .seconds(1)))
        await reconnector.networkAvailable(false)
        #expect(await states.next(isolation: #isolation) == .waitingForNetwork(attempt: 1))
        clock.advance(by: .seconds(60))
        #expect(script.callCount == 0)
        await reconnector.networkAvailable(true)
        let seen = await follow(&states, count: 2)
        #expect(seen == [.waiting(attempt: 1, delay: .seconds(1)), .trying(attempt: 1)])
        #expect(await run.value == .reconnected)
        #expect(clock.now.offset == .seconds(61))
    }

    /// The person asked: the network's state may be wrong (a VPN, say).
    @Test func reconnectNowTriesEvenOffline() async {
        let script = Script([.outcome(.streaming)])
        let reconnector = Reconnector(clock: clock, attempt: script.next)
        await reconnector.networkAvailable(false)
        var states = reconnector.states.makeAsyncIterator()
        let run = Task { await reconnector.run(after: .connectionLost) }
        #expect(await states.next(isolation: #isolation) == .waitingForNetwork(attempt: 1))
        await reconnector.reconnectNow()
        #expect(await states.next(isolation: #isolation) == .trying(attempt: 1))
        #expect(await run.value == .reconnected)
    }

    @Test func offlineBeforeTheRunWaitsForTheNetwork() async {
        let script = Script([.outcome(.streaming)])
        let reconnector = Reconnector(clock: clock, attempt: script.next)
        await reconnector.networkAvailable(false)
        var states = reconnector.states.makeAsyncIterator()
        let run = Task { await reconnector.run(after: .connectionLost) }
        #expect(await states.next(isolation: #isolation) == .waitingForNetwork(attempt: 1))
        await reconnector.networkAvailable(true)
        let seen = await follow(&states, count: 2)
        #expect(seen == [.waiting(attempt: 1, delay: .seconds(1)), .trying(attempt: 1)])
        #expect(await run.value == .reconnected)
    }

    @Test func cancellingDuringAWaitStopsEveryLaterTry() async {
        let script = Script([.outcome(.streaming)])
        let reconnector = Reconnector(clock: clock, attempt: script.next)
        var states = reconnector.states.makeAsyncIterator()
        let run = Task { await reconnector.run(after: .connectionLost) }
        #expect(await states.next(isolation: #isolation) == .waiting(attempt: 1, delay: .seconds(1)))
        run.cancel()
        #expect(await run.value == .cancelled)
        clock.advance(by: .seconds(60))
        #expect(script.callCount == 0)
    }

    @Test func cancellingDuringATryStopsEveryLaterTry() async {
        let script = Script([.hang, .outcome(.streaming)])
        let reconnector = Reconnector(clock: clock, attempt: script.next)
        var states = reconnector.states.makeAsyncIterator()
        let run = Task { await reconnector.run(after: .connectionLost) }
        let seen = await follow(&states, count: 2)
        #expect(seen.last == .trying(attempt: 1))
        run.cancel()
        #expect(await run.value == .cancelled)
        clock.advance(by: .seconds(60))
        #expect(script.callCount == 1)
    }

    /// A wait that ended as the person pressed Disconnect starts no try.
    @Test func aCancelAsTheWaitEndsStartsNoTry() async {
        let script = Script([.outcome(.streaming)])
        let reconnector = Reconnector(clock: clock, attempt: script.next)
        var states = reconnector.states.makeAsyncIterator()
        let run = Task { await reconnector.run(after: .connectionLost) }
        #expect(await states.next(isolation: #isolation) == .waiting(attempt: 1, delay: .seconds(1)))
        run.cancel()
        await reconnector.reconnectNow()
        #expect(await run.value == .cancelled)
        #expect(script.callCount == 0)
    }

    /// A try that streamed is reported, even as a Disconnect lands: its session is the
    /// caller's to end.
    @Test func aTryThatStreamsAsItIsCancelledReconnects() async {
        let script = Script([.onCancel(.streaming)])
        let reconnector = Reconnector(clock: clock, attempt: script.next)
        var states = reconnector.states.makeAsyncIterator()
        let run = Task { await reconnector.run(after: .connectionLost) }
        _ = await follow(&states, count: 2)
        run.cancel()
        #expect(await run.value == .reconnected)
    }

    /// A session that streamed for `steadyTime` before it ended: the next run counts afresh.
    @Test func aRunAfterASteadySessionStartsAgain() async {
        let script = Script([.outcome(.ended(.connectionLost)), .outcome(.streaming), .outcome(.streaming)])
        let reconnector = Reconnector(clock: clock, attempt: script.next)
        var states = reconnector.states.makeAsyncIterator()
        let first = Task { await reconnector.run(after: .connectionLost) }
        _ = await follow(&states, count: 4)
        #expect(await first.value == .reconnected)
        clock.advance(by: ReconnectMemory.steadyTime)
        let second = Task { await reconnector.run(after: .connectionLost) }
        let seen = await follow(&states, count: 2)
        #expect(seen == [.waiting(attempt: 1, delay: .seconds(1)), .trying(attempt: 1)])
        #expect(await second.value == .reconnected)
    }

    /// A host that streams, then drops at once, each time: the count goes on from the last
    /// run, so the waits grow and the tries run out rather than going on every second.
    @Test func aSessionThatDropsSoonCarriesTheCount() async {
        let lost = Script.Step.outcome(.ended(.connectionLost))
        let script = Script([lost, .outcome(.streaming), .outcome(.streaming), lost, lost])
        let reconnector = Reconnector(clock: clock, attempt: script.next)
        var states = reconnector.states.makeAsyncIterator()
        let first = Task { await reconnector.run(after: .connectionLost) }
        _ = await follow(&states, count: 4)
        #expect(await first.value == .reconnected)
        clock.advance(by: ReconnectMemory.steadyTime - .seconds(1))
        let second = Task { await reconnector.run(after: .connectionLost) }
        let seen = await follow(&states, count: 2)
        #expect(seen == [.waiting(attempt: 3, delay: .seconds(4)), .trying(attempt: 3)])
        #expect(await second.value == .reconnected)
        let third = Task { await reconnector.run(after: .connectionLost) }
        let last: [ReconnectState] = [
            .waiting(attempt: 4, delay: .seconds(8)), .trying(attempt: 4),
            .waiting(attempt: 5, delay: .seconds(16)), .trying(attempt: 5),
        ]
        let seenLast = await follow(&states, count: 4)
        #expect(seenLast == last)
        // Counting afresh, it would wait for a try past the script's end.
        if seenLast != last { third.cancel() }
        #expect(await third.value == .gaveUp(.connectionLost))
    }

    /// The window makes a reconnector per run; a memory they share carries the count.
    @Test func aSharedMemoryCarriesTheCountToTheNextReconnector() async {
        let memory = ReconnectMemory(clock: clock)
        let script = Script([.outcome(.streaming), .outcome(.streaming)])
        let first = Reconnector(clock: clock, memory: memory, attempt: script.next)
        var firstStates = first.states.makeAsyncIterator()
        let run = Task { await first.run(after: .connectionLost) }
        _ = await follow(&firstStates, count: 2)
        #expect(await run.value == .reconnected)
        let second = Reconnector(clock: clock, memory: memory, attempt: script.next)
        var states = second.states.makeAsyncIterator()
        let next = Task { await second.run(after: .connectionLost) }
        #expect(
            await follow(&states, count: 2) == [
                .waiting(attempt: 2, delay: .seconds(2)), .trying(attempt: 2),
            ])
        #expect(await next.value == .reconnected)
    }

    /// A try that streams as the person connects elsewhere (forgetting the count) leaves no count.
    @Test func aForgetDuringATryWins() async {
        let memory = ReconnectMemory(clock: clock)
        let reconnector = Reconnector(clock: clock, memory: memory) {
            memory.forget()
            return .streaming
        }
        var states = reconnector.states.makeAsyncIterator()
        let first = Task { await reconnector.run(after: .connectionLost) }
        _ = await follow(&states, count: 2)
        #expect(await first.value == .reconnected)
        let second = Task { await reconnector.run(after: .connectionLost) }
        #expect(
            await follow(&states, count: 2) == [
                .waiting(attempt: 1, delay: .seconds(1)), .trying(attempt: 1),
            ])
        #expect(await second.value == .reconnected)
    }

    /// A connection the person makes forgets the count.
    @Test func forgettingStartsTheCountAgain() async {
        let memory = ReconnectMemory(clock: clock)
        let script = Script([.outcome(.streaming), .outcome(.streaming)])
        let reconnector = Reconnector(clock: clock, memory: memory, attempt: script.next)
        var states = reconnector.states.makeAsyncIterator()
        let first = Task { await reconnector.run(after: .connectionLost) }
        _ = await follow(&states, count: 2)
        #expect(await first.value == .reconnected)
        memory.forget()
        let second = Task { await reconnector.run(after: .connectionLost) }
        #expect(
            await follow(&states, count: 2) == [
                .waiting(attempt: 1, delay: .seconds(1)), .trying(attempt: 1),
            ])
        #expect(await second.value == .reconnected)
    }

    /// Reconnect Now during a try does nothing, and says so: the app's "asked" mark mustn't
    /// carry over to the next automatic try.
    @Test func reconnectNowDuringATrySaysItDidNothing() async {
        let script = Script([.hang])
        let reconnector = Reconnector(clock: clock, attempt: script.next)
        var states = reconnector.states.makeAsyncIterator()
        let run = Task { await reconnector.run(after: .connectionLost) }
        #expect(await states.next(isolation: #isolation) == .waiting(attempt: 1, delay: .seconds(1)))
        #expect(await reconnector.reconnectNow())
        #expect(await states.next(isolation: #isolation) == .trying(attempt: 1))
        #expect(await !reconnector.reconnectNow())
        run.cancel()
        _ = await run.value
    }

    /// One run at a time: a second while one is under way is refused, and the first goes on.
    @Test func aSecondRunIsRefused() async {
        let script = Script([.outcome(.streaming)])
        let reconnector = Reconnector(clock: clock, attempt: script.next)
        var states = reconnector.states.makeAsyncIterator()
        let first = Task { await reconnector.run(after: .connectionLost) }
        #expect(await states.next(isolation: #isolation) == .waiting(attempt: 1, delay: .seconds(1)))
        #expect(await reconnector.run(after: .connectionLost) == .cancelled)
        await reconnector.reconnectNow()
        #expect(await first.value == .reconnected)
    }
}
