import GliffTestSupport
import Testing

/// A test's wait on a task ends at its bound, even when the task ignores cancellation.
@Suite struct BoundedWaitTests {
    @Test func aTaskThatNeverEndsTimesOut() async {
        let stuck = Task.detached {
            await withUnsafeContinuation { (_: UnsafeContinuation<Int, Never>) in }
        }
        let started = ContinuousClock.now
        await #expect(throws: TimedOut.self) { try await stuck.valueWithin(.milliseconds(50)) }
        #expect(ContinuousClock.now - started < .seconds(5))
    }

    @Test func aTaskThatEndsGivesItsOutcome() async throws {
        #expect(try await Task { 7 }.valueWithin() == 7)
        let failing = Task { () throws(TimedOut) -> Int in throw TimedOut() }
        await #expect(throws: TimedOut.self) { try await failing.valueWithin() }
        let outcome = try await failing.resultWithin()
        #expect(throws: TimedOut.self) { try outcome.get() }
    }
}
