import Testing

@testable import GliffInput

/// The confined pointer: deltas move it inside the output; a host report near a recent motion
/// is its echo, any other is a warp to follow.
@Suite struct VirtualPointerTests {
    private func pointer(x: Double = 100, y: Double = 100) -> VirtualPointer {
        VirtualPointer(x: x, y: y, width: 1280, height: 720)
    }

    private static func ms(_ value: Int) -> Duration { .milliseconds(value) }

    /// `hostReported`, callable inside `#expect`.
    private func report(
        _ virtual: inout VirtualPointer, x: Double, y: Double, visible: Bool, at time: Duration
    ) -> Bool {
        virtual.hostReported(x: x, y: y, visible: visible, at: time)
    }

    /// A delta and where it stops, from (100, 100).
    @Test(arguments: [
        (-2000.0, 0.0, 0.0, 100.0), (2000, 0, 1279, 100), (0, -2000, 100, 0), (0, 2000, 100, 719),
    ])
    func aDeltaStopsAtTheEdge(_ dx: Double, _ dy: Double, _ x: Double, _ y: Double) {
        var virtual = pointer()
        let sent = virtual.move(dx: dx, dy: dy, at: .zero)
        #expect(sent == (x, y))
        #expect(sent == (virtual.x, virtual.y))
    }

    @Test func fractionalDeltasAccumulate() {
        var virtual = pointer()
        for step in 0..<10 { _ = virtual.move(dx: 0.25, dy: 0, at: Self.ms(step)) }
        #expect(virtual.x == 102.5)
    }

    @Test func theHistoryModelsTheServersRounding() {
        #expect(VirtualPointer.applied(100.4, extent: 1280) == 100)
        #expect(VirtualPointer.applied(100.5, extent: 1280) == 101)
        #expect(VirtualPointer.applied(100.6, extent: 1280) == 101)
        #expect(VirtualPointer.applied(-50, extent: 1280) == 0)
        #expect(VirtualPointer.applied(1330, extent: 1280) == 1279)
    }

    @Test func anEchoIsIgnored() {
        var virtual = pointer()
        _ = virtual.move(dx: 10.5, dy: 0, at: .zero)
        #expect(!report(&virtual, x: 111, y: 100, visible: true, at: Self.ms(20)))
        #expect(virtual.x == 110.5)
    }

    /// An older motion's echo arriving after newer motions is still an echo.
    @Test func aLateEchoIsIgnored() {
        var virtual = pointer()
        _ = virtual.move(dx: 10, dy: 0, at: .zero)
        _ = virtual.move(dx: 10, dy: 0, at: Self.ms(10))
        #expect(!report(&virtual, x: 110, y: 100, visible: true, at: Self.ms(30)))
        #expect(virtual.x == 120)
    }

    @Test func aWarpIsAdopted() {
        var virtual = pointer()
        _ = virtual.move(dx: 10, dy: 0, at: .zero)
        #expect(report(&virtual, x: 500, y: 300, visible: true, at: Self.ms(20)))
        #expect(virtual.x == 500)
        #expect(virtual.y == 300)
    }

    @Test func anInvisiblePositionHidesWithoutMoving() {
        var virtual = pointer()
        #expect(!report(&virtual, x: 500, y: 300, visible: false, at: .zero))
        #expect(!virtual.visible)
        #expect(virtual.x == 100)
    }

    @Test func theNextVisiblePositionShowsAgain() {
        var virtual = pointer()
        _ = virtual.hostReported(x: 500, y: 300, visible: false, at: .zero)
        _ = virtual.hostReported(x: 100, y: 100, visible: true, at: Self.ms(10))
        #expect(virtual.visible)
    }

    @Test func withNothingSentAFarPositionIsAdopted() {
        var virtual = pointer()
        _ = virtual.move(dx: 10, dy: 0, at: .zero)
        var near = virtual
        #expect(!report(&near, x: 111, y: 100, visible: true, at: Self.ms(1100)))
        #expect(report(&virtual, x: 112, y: 100, visible: true, at: Self.ms(1100)))
    }

    @Test func theHistoryForgetsAfterOneSecond() {
        var virtual = pointer()
        _ = virtual.move(dx: 100, dy: 0, at: .zero)
        _ = virtual.move(dx: 100, dy: 0, at: Self.ms(500))
        #expect(report(&virtual, x: 200, y: 100, visible: true, at: Self.ms(1200)))
        var kept = pointer()
        _ = kept.move(dx: 100, dy: 0, at: .zero)
        _ = kept.move(dx: 100, dy: 0, at: Self.ms(500))
        #expect(!report(&kept, x: 200, y: 100, visible: true, at: Self.ms(900)))
    }

    /// A mouse reporting at 1 kHz: a second of its motions stays in the history.
    @Test func theHistoryHoldsASecondAtAThousandHertz() {
        #expect(VirtualPointer.historyLimit >= 1000)
    }

    @Test func theHistoryKeepsItsLimit() {
        var virtual = VirtualPointer(x: 0, y: 0, width: 100_000, height: 720)
        let moves = VirtualPointer.historyLimit + 1
        for step in 0..<moves { _ = virtual.move(dx: 10, dy: 0, at: .microseconds(step * 500)) }
        let last = Duration.microseconds(moves * 500)
        // The first motion's (10, 0) has left the history; the second's (20, 0) hasn't.
        var second = virtual
        #expect(!report(&second, x: 20, y: 0, visible: true, at: last))
        #expect(report(&virtual, x: 10, y: 0, visible: true, at: last))
    }

    @Test func aNewSizeClamps() {
        var virtual = pointer(x: 1200)
        virtual.resize(width: 1024, height: 768)
        #expect(virtual.x == 1023)
        #expect(virtual.y == 100)
    }

    /// The same output in a new stream size: the place and the echoes scale with it.
    @Test func aRescaleKeepsThePlaceAndItsEchoes() {
        var virtual = pointer(x: 600, y: 300)
        _ = virtual.move(dx: 10, dy: 0, at: .zero)
        virtual.resize(width: 640, height: 360, keepingPlace: true)
        #expect(virtual.x == 305)
        #expect(virtual.y == 150)
        #expect(!report(&virtual, x: 305, y: 150, visible: true, at: Self.ms(20)))
    }

    /// The host's pointer comes back onto the output: its first report is where it left
    /// (upstream's cursor-session Enter), no warp.
    @Test func comingBackWhereItLeftIsNoWarp() {
        var virtual = pointer()
        _ = report(&virtual, x: 500, y: 300, visible: false, at: .zero)
        #expect(!report(&virtual, x: 500, y: 300, visible: true, at: .seconds(2)))
        #expect(virtual.visible)
        #expect(virtual.x == 100)
        // After that, a far position is a warp again.
        #expect(report(&virtual, x: 500, y: 300, visible: true, at: .seconds(3)))
    }
}
