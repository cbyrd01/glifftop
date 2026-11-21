import Testing

@testable import GliffSession

/// When a streaming session counts as interrupted: one of the client's Pings has gone
/// unanswered for `answerWithin` and nothing at all, not a byte, has arrived for
/// `silenceLimit`. Times are a monotonic clock's milliseconds.
@Suite struct LivenessTests {
    /// The checks at each time, in order: whether each one reported a new interruption.
    private func checks(_ liveness: inout Liveness, at times: [UInt64]) -> [Bool] {
        times.map { liveness.check(at: $0) }
    }

    @Test func anUnansweredPingAndSilenceInterrupt() {
        var liveness = Liveness()
        liveness.heard(at: 0)
        liveness.pinged(at: 1000)
        let limit = Liveness.silenceLimit
        // Reported once, not on every check.
        #expect(checks(&liveness, at: [limit - 1, limit, limit + 500]) == [false, true, false])
        #expect(liveness.isInterrupted)
        let resumed = liveness.heard(at: limit + 600)
        #expect(resumed)
        #expect(!liveness.isInterrupted)
        let again = liveness.heard(at: limit + 700)
        #expect(!again)
    }

    /// A late tick (App Nap) sends its overdue Ping and checks at once: the server hasn't had
    /// a chance to answer, so that isn't an interruption, however long since the last byte.
    @Test func aFreshPingCantInterrupt() {
        var liveness = Liveness()
        liveness.heard(at: 0)
        liveness.pinged(at: 10_000)
        let answer = Liveness.answerWithin
        #expect(
            checks(&liveness, at: [10_000, 10_000 + answer - 1, 10_000 + answer]) == [false, false, true])
    }

    /// Bytes of a frame still arriving (a slow keyframe) count as hearing from the server.
    @Test func anyBytesKeepTheLinkLive() {
        var liveness = Liveness()
        liveness.pinged(at: 0)
        var seen: [Bool] = []
        for now in stride(from: UInt64(1000), through: 30_000, by: 1000) {
            liveness.heard(at: now)
            liveness.pinged(at: now)
            seen += checks(&liveness, at: [now + 500])
        }
        #expect(!seen.contains(true))
    }

    /// No Ping, no verdict: before streaming the client sends none.
    @Test func withoutAPingNothingInterrupts() {
        var liveness = Liveness()
        liveness.heard(at: 0)
        #expect(checks(&liveness, at: [60_000]) == [false])
    }

    /// A Ping sent before anything arrived counts from when it was sent.
    @Test func silenceBeforeAnyByteCountsFromThePing() {
        var liveness = Liveness()
        liveness.pinged(at: 1000)
        let limit = Liveness.silenceLimit
        #expect(checks(&liveness, at: [1000 + limit - 1, 1000 + limit]) == [false, true])
    }
}
