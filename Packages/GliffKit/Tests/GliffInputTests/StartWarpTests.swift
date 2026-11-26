import Testing

@testable import GliffInput

/// A motion soon after confinement's warp to the centre: the warp taken out of it when it
/// carries it, the hand's own motion left; nil when it doesn't carry it.
@Suite struct StartWarpTests {
    @Test func theWarpAloneLeavesNothing() {
        let motion = StartWarp.handMotion(delta: (780, -200), warp: (780, -200))
        #expect(motion?.dx == 0 && motion?.dy == 0)
    }

    @Test func theWarpWithTheHandLeavesTheHand() {
        let motion = StartWarp.handMotion(delta: (783, -198), warp: (780, -200))
        #expect(motion?.dx == 3 && motion?.dy == 2)
    }

    @Test func aDeltaWithoutTheWarpDoesNotCarryIt() {
        #expect(StartWarp.handMotion(delta: (3, 2), warp: (780, -200)) == nil)
    }

    @Test func aDeltaAgainstTheWarpDoesNotCarryIt() {
        #expect(StartWarp.handMotion(delta: (-20, 5), warp: (30, 0)) == nil)
    }

    /// A short warp: a quick motion of the hand alone isn't taken for it.
    @Test func aShortWarpKeepsAQuickMotion() {
        #expect(StartWarp.handMotion(delta: (20, 0), warp: (30, 0)) == nil)
    }
}
