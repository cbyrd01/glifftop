import Testing

@testable import GliffSession

/// The host's pointer, for the app to poll: each report moves the generation, so one at the
/// same place is still seen.
@Suite struct RemotePointerSlotTests {
    @Test func eachPublishMovesTheGeneration() {
        let slot = RemotePointerSlot()
        let position = RemotePointerSlot.Position(x: 1, y: 2, visible: true)
        slot.publish(position)
        slot.publish(position)
        slot.publish(nil)
        let read = slot.read()
        #expect(read.position == nil)
        #expect(read.generation == 3)
    }

    @Test func aNewSlotStartsAtZero() {
        let read = RemotePointerSlot().read()
        #expect(read.position == nil)
        #expect(read.generation == 0)
    }

    @Test func reportsAfterAGenerationComeInOrder() {
        let slot = RemotePointerSlot()
        let positions = (1...3).map { RemotePointerSlot.Position(x: Double($0), y: 0, visible: true) }
        for position in positions { slot.publish(position) }
        slot.publish(nil)
        let reports = slot.reports(after: 1)
        #expect(reports.positions == [positions[1], positions[2], nil])
        #expect(reports.generation == 4)
        #expect(slot.reports(after: 4).positions.isEmpty)
    }

    @Test func onlyTheRecentReportsAreKept() {
        let slot = RemotePointerSlot()
        let count = RemotePointerSlot.recentLimit + 5
        for index in 0..<count { slot.publish(.init(x: Double(index), y: 0, visible: true)) }
        let positions = slot.reports(after: 0).positions
        #expect(positions.count == RemotePointerSlot.recentLimit)
        #expect(positions.last??.x == Double(count - 1))
    }

    /// A generation the slot hasn't reached (another slot's): nothing new.
    @Test func aGenerationAheadGetsNothing() {
        let slot = RemotePointerSlot()
        slot.publish(RemotePointerSlot.Position(x: 1, y: 2, visible: true))
        let reports = slot.reports(after: 5)
        #expect(reports.positions.isEmpty)
        #expect(reports.generation == 1)
    }

    @Test func readMatchesLatest() {
        let slot = RemotePointerSlot()
        let position = RemotePointerSlot.Position(x: 1, y: 2, visible: false)
        slot.publish(position)
        #expect(slot.read().position == position)
        #expect(slot.latest == position)
    }
}
