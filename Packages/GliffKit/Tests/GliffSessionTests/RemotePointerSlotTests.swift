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

    @Test func readMatchesLatest() {
        let slot = RemotePointerSlot()
        let position = RemotePointerSlot.Position(x: 1, y: 2, visible: false)
        slot.publish(position)
        #expect(slot.read().position == position)
        #expect(slot.latest == position)
    }
}
