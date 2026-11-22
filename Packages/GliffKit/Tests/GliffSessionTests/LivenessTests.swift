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

    /// After a wake: a Ping sent at once, and the link counts as lost unless that Ping's Pong
    /// arrives within `probeLimit`. Reported once.
    @Test func aProbeWithoutAnswerFailsAfterThreeSeconds() {
        var liveness = Liveness()
        liveness.heard(at: 0)
        liveness.probe(ping: 7, at: 1000)
        let failed = [3999, 4000, 4500].map { liveness.probeFailed(at: $0) }
        #expect(failed == [false, true, false])
    }

    @Test func theProbesPongAnswersIt() {
        var liveness = Liveness()
        liveness.probe(ping: 7, at: 0)
        liveness.answered(ping: 7)
        let failed = liveness.probeFailed(at: 10_000)
        #expect(!failed)
    }

    /// Bytes already on their way when the Mac slept (arriving at once), or an older Ping's
    /// Pong, prove nothing about the link now.
    @Test func otherBytesDontAnswerIt() {
        var liveness = Liveness()
        liveness.probe(ping: 7, at: 0)
        liveness.heard(at: 10)
        liveness.answered(ping: 6)
        let failed = liveness.probeFailed(at: 3000)
        #expect(failed)
    }

    /// Bytes a second or more after the probe travelled the link since: a slow link's Pong,
    /// queued behind a keyframe, needn't end it.
    @Test func bytesASecondLaterAnswerIt() {
        var liveness = Liveness()
        liveness.probe(ping: 7, at: 0)
        liveness.heard(at: 999)
        let early = liveness.probeFailed(at: 3000)
        liveness.probe(ping: 8, at: 4000)
        liveness.heard(at: 5000)
        let late = liveness.probeFailed(at: 7000)
        #expect(early)
        #expect(!late)
    }

    /// A probe after a second wake gets its own time, and only its own Pong answers it.
    @Test func aSecondProbeStartsAgain() {
        var liveness = Liveness()
        liveness.probe(ping: 7, at: 1000)
        liveness.probe(ping: 9, at: 3900)
        liveness.answered(ping: 7)
        let failed = [4000, 6899, 6900].map { liveness.probeFailed(at: $0) }
        #expect(failed == [false, false, true])
    }

    @Test func withoutAProbeNothingFails() {
        var liveness = Liveness()
        liveness.heard(at: 0)
        let failed = liveness.probeFailed(at: 60_000)
        #expect(!failed)
    }
}
