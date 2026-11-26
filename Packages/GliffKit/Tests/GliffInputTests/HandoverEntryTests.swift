import Testing

@testable import GliffInput

/// A handover's entry point: the next activation's target for 500 ms, used once.
@Suite struct HandoverEntryTests {
    private let start = ContinuousClock.now

    @Test func itIsTheTargetWithinItsLifetime() {
        var entry = HandoverEntry()
        entry.set(x: 10, y: 20, at: start)
        let point = entry.take(at: start + .milliseconds(499))
        #expect(point?.x == 10 && point?.y == 20)
    }

    @Test func itGoesAfter500ms() {
        var entry = HandoverEntry()
        entry.set(x: 10, y: 20, at: start)
        #expect(entry.take(at: start + .milliseconds(500)) == nil)
    }

    @Test func itIsUsedOnce() {
        var entry = HandoverEntry()
        entry.set(x: 10, y: 20, at: start)
        _ = entry.take(at: start)
        #expect(entry.take(at: start) == nil)
    }

    @Test func clearingDropsIt() {
        var entry = HandoverEntry()
        entry.set(x: 10, y: 20, at: start)
        entry.clear()
        #expect(entry.take(at: start) == nil)
    }

    @Test func noneSetIsNoTarget() {
        var entry = HandoverEntry()
        #expect(entry.take(at: start) == nil)
    }
}
