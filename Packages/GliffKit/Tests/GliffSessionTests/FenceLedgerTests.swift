import Testing

@testable import GliffSession

/// `FenceLedger`: a release is answered by the Pong to the Ping behind it, or to a later one.
@Suite struct FenceLedgerTests {
    private let first = InputBarrier.Release(sender: InputBarrier.Sender(), number: 1)
    private let second = InputBarrier.Release(sender: InputBarrier.Sender(), number: 2)

    @Test func thePongToThePingBehindAReleaseAnswersIt() {
        var ledger = FenceLedger()
        ledger.sent([first])
        ledger.pingSent(t: 1)
        #expect(ledger.pongHeard(t: 1) == [first])
        #expect(ledger.pongHeard(t: 1).isEmpty)
    }

    /// A Ping sent before the release (the stats', a probe's) is answered first: its Pong
    /// answers nothing.
    @Test func anEarlierPingsPongAnswersNothing() {
        var ledger = FenceLedger()
        ledger.pingSent(t: 1)
        ledger.sent([first])
        ledger.pingSent(t: 2)
        #expect(ledger.pongHeard(t: 1).isEmpty)
        #expect(ledger.pongHeard(t: 2) == [first])
    }

    /// Upstream's writer drops a Pong still queued when a newer one is queued: the newer Pong
    /// answers every Ping up to its own.
    @Test func aPongAnswersTheEarlierPingsWhosePongsWereDropped() {
        var ledger = FenceLedger()
        ledger.sent([first])
        ledger.pingSent(t: 1)
        ledger.pingSent(t: 2)
        ledger.sent([second])
        ledger.pingSent(t: 3)
        #expect(ledger.pongHeard(t: 3) == [first, second])
        #expect(ledger.pongHeard(t: 1).isEmpty)
    }

    /// Releases behind two Pings: each answered by its own Ping's Pong, in order.
    @Test func eachReleaseWaitsForItsOwnPing() {
        var ledger = FenceLedger()
        ledger.sent([first])
        ledger.pingSent(t: 1)
        ledger.pingSent(t: 2)
        ledger.sent([second])
        ledger.pingSent(t: 3)
        #expect(ledger.pongHeard(t: 1) == [first])
        #expect(ledger.pongHeard(t: 2).isEmpty)
        #expect(ledger.pongHeard(t: 3) == [second])
    }

    /// A Ping sent after the release's own answers nothing more for it.
    @Test func aLaterPingIsntNeeded() {
        var ledger = FenceLedger()
        ledger.sent([first, second])
        ledger.pingSent(t: 1)
        ledger.pingSent(t: 2)
        #expect(ledger.pongHeard(t: 1) == [first, second])
    }

    /// A Pong to no Ping waiting (one before the stream, or never sent) answers nothing.
    @Test func aPongToAnUnknownPingAnswersNothing() {
        var ledger = FenceLedger()
        ledger.sent([first])
        ledger.pingSent(t: 5)
        #expect(ledger.pongHeard(t: 4).isEmpty)
        #expect(ledger.pongHeard(t: 5) == [first])
    }

    /// Two Pings with one `t`: the Pong counts as the first one's, so a release behind the
    /// second waits for the second Pong rather than going early.
    @Test func aPongToARepeatedTCountsAsTheFirstPings() {
        var ledger = FenceLedger()
        ledger.pingSent(t: 5)
        ledger.sent([first])
        ledger.pingSent(t: 5)
        #expect(ledger.pongHeard(t: 5).isEmpty)
        #expect(ledger.pongHeard(t: 5) == [first])
    }

    /// A server that never answers can't grow the ledger without bound: the oldest Ping is
    /// forgotten, and what waits for its releases waits out the limit.
    @Test func theLedgerKeepsAtMostItsLimit() {
        var ledger = FenceLedger()
        ledger.sent([first])
        ledger.pingSent(t: 0)
        for t in 1..<UInt64(FenceLedger.maxWaiting) { ledger.pingSent(t: t) }
        ledger.sent([second])
        ledger.pingSent(t: UInt64(FenceLedger.maxWaiting))
        #expect(ledger.pongHeard(t: 0).isEmpty)
        #expect(ledger.pongHeard(t: UInt64(FenceLedger.maxWaiting)) == [second])
    }

    /// Releases sent while no Ping can go (no stream) go with the next Ping sent.
    @Test func releasesSentWithoutAPingWaitForTheNext() {
        var ledger = FenceLedger()
        ledger.sent([first])
        #expect(ledger.pongHeard(t: 1).isEmpty)
        ledger.pingSent(t: 2)
        #expect(ledger.pongHeard(t: 2) == [first])
    }

    /// The session ended: no Pong is coming, and every release not yet answered is returned,
    /// pinged or not.
    @Test func theEndReturnsEveryReleaseUnanswered() {
        var ledger = FenceLedger()
        ledger.sent([first])
        ledger.pingSent(t: 1)
        ledger.sent([second])
        #expect(ledger.ended() == [first, second])
        #expect(ledger.ended().isEmpty)
        #expect(ledger.pongHeard(t: 1).isEmpty)
    }

    /// Releases sent through a long stretch without a stream can't grow the ledger without
    /// bound either.
    @Test func releasesWithoutAPingAreKeptToTheLimit() {
        var ledger = FenceLedger()
        ledger.sent([first])
        for _ in 0..<FenceLedger.maxWaiting { ledger.sent([second]) }
        let ended = ledger.ended()
        #expect(ended.count == FenceLedger.maxWaiting)
        #expect(!ended.contains(first))
    }
}
