import Testing

@testable import GliffSession

/// The Debug inspector's numbers: per type and direction, counts and sizes only.
@Suite struct ProtocolTallyTests {
    private let start = ContinuousClock.now

    private func event(
        _ direction: ProtocolEvent.Direction, _ type: String, bytes: Int = 10, at seconds: Double = 0
    ) -> ProtocolEvent {
        ProtocolEvent(direction: direction, type: type, bytes: bytes, time: start + .seconds(seconds))
    }

    @Test func countsAndBytesPerTypeAndDirection() {
        var tally = ProtocolTally()
        tally.add(event(.received, "VideoFrame", bytes: 100, at: 0))
        tally.add(event(.received, "VideoFrame", bytes: 50, at: 0.5))
        tally.add(event(.sent, "FrameAck", bytes: 20, at: 0.6))
        tally.add(event(.received, "FrameAck", bytes: 7, at: 0.7))
        let rows = tally.rows(now: start + .seconds(0.8))
        #expect(rows.map(\.type) == ["FrameAck", "FrameAck", "VideoFrame"])
        #expect(rows.map(\.direction) == [.sent, .received, .received])
        #expect(rows[2].count == 2 && rows[2].bytes == 150)
        #expect(rows[2].last == start + .seconds(0.5))
        #expect(rows[0].count == 1 && rows[0].bytes == 20)
    }

    @Test func perSecondCountsOnlyTheLastSecond() {
        var tally = ProtocolTally()
        for tenth in 0..<20 { tally.add(event(.received, "VideoFrame", at: Double(tenth) / 10)) }
        // At 2.0 s the last second holds 1.1 … 1.9: nine.
        #expect(tally.rows(now: start + .seconds(2)).first?.perSecond == 9)
        #expect(tally.rows(now: start + .seconds(5)).first?.perSecond == 0)
        #expect(tally.rows(now: start + .seconds(5)).first?.count == 20)
    }

    @Test func recentKeepsTheLast200() {
        var tally = ProtocolTally()
        for index in 0..<250 { tally.add(event(.sent, "Key", bytes: index)) }
        #expect(tally.recent.count == ProtocolTally.recentLimit)
        #expect(tally.recent.first?.bytes == 50)
        #expect(tally.recent.last?.bytes == 249)
    }

    @Test func clearEmptiesIt() {
        var tally = ProtocolTally()
        tally.add(event(.sent, "Key"))
        tally.clear()
        #expect(tally.rows(now: start).isEmpty)
        #expect(tally.recent.isEmpty)
    }

    /// No payload, no field values: an event is its direction, type, size and time.
    @Test func theObserverNeverSeesAPayload() {
        #expect(Mirror(reflecting: event(.sent, "Key")).children.count == 4)
    }
}
