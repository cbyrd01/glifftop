import Testing

@testable import GliffSession

/// One reader of the host's pointer for a confined pointer: confinement starts from one look,
/// and each look after gives every report since the last.
@Suite struct HostPointerFollowerTests {
    @Test func aStartWithNoReportsTakesNothing() {
        var follower = HostPointerFollower(RemotePointerSlot())
        let start = follower.start()
        #expect(start.latest == nil)
        #expect(start.hiddenAt == nil)
        #expect(!start.newPicture)
    }

    @Test func aStartWhileHiddenTakesTheHiddenPlace() {
        let slot = RemotePointerSlot()
        slot.publish(RemotePointerSlot.Position(x: 5, y: 6, visible: false))
        var follower = HostPointerFollower(slot)
        let start = follower.start()
        #expect(start.latest == RemotePointerSlot.Position(x: 5, y: 6, visible: false))
        #expect(start.hiddenAt?.bufferX == 5)
        #expect(start.hiddenAt?.bufferY == 6)
        #expect(!start.newPicture)
    }

    @Test func aStartWhileShownHidesNothing() {
        let slot = RemotePointerSlot()
        slot.publish(RemotePointerSlot.Position(x: 5, y: 6, visible: true))
        var follower = HostPointerFollower(slot)
        #expect(follower.start().hiddenAt == nil)
    }

    /// The last report a new picture's announcement (nil, after reports began).
    @Test func aStartAfterANewPictureSaysSo() {
        let slot = RemotePointerSlot()
        slot.publish(RemotePointerSlot.Position(x: 5, y: 6, visible: true))
        slot.publish(nil)
        var follower = HostPointerFollower(slot)
        let start = follower.start()
        #expect(start.hiddenAt == nil)
        #expect(start.newPicture)
    }

    @Test func onlyReportsAfterTheStartAreFollowed() {
        let slot = RemotePointerSlot()
        slot.publish(RemotePointerSlot.Position(x: 1, y: 2, visible: true))
        var follower = HostPointerFollower(slot)
        _ = follower.start()
        slot.publish(RemotePointerSlot.Position(x: 3, y: 4, visible: false))
        slot.publish(nil)
        let reports = follower.reports()
        #expect(reports.count == 2)
        #expect(reports.first??.bufferX == 3)
        #expect(reports.first??.bufferY == 4)
        #expect(reports.first??.visible == false)
        #expect(reports.last! == nil)
    }

    @Test func eachReportComesOnce() {
        let slot = RemotePointerSlot()
        var follower = HostPointerFollower(slot)
        slot.publish(RemotePointerSlot.Position(x: 1, y: 2, visible: true))
        #expect(follower.reports().count == 1)
        #expect(follower.reports().isEmpty)
    }
}
