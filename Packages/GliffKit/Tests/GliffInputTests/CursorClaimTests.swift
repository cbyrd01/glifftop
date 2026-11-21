import GliffInput
import Testing

/// The picture gives back only the cursor it showed, and only while that is still the one
/// shown: a cursor set since (by AppKit, an overlay, another window) is left alone.
@Suite struct CursorClaimTests {
    private final class Token {}
    private let a = Token()
    private let b = Token()

    @Test func theCursorShownIsGivenBack() {
        var claim = CursorClaim<Token>()
        claim.show(a)
        let given = claim.giveBack(current: a, liveResize: false)
        #expect(given)
    }

    @Test func aCursorSetBySomeoneElseIsLeftAlone() {
        var claim = CursorClaim<Token>()
        claim.show(a)
        let other = claim.giveBack(current: b, liveResize: false)
        #expect(!other)
        // The claim ended: the picture's cursor coming back later isn't the picture's to take.
        let later = claim.giveBack(current: a, liveResize: false)
        #expect(!later)
    }

    @Test func givenBackOnce() {
        var claim = CursorClaim<Token>()
        claim.show(a)
        let first = claim.giveBack(current: a, liveResize: false)
        let second = claim.giveBack(current: a, liveResize: false)
        #expect(first && !second)
    }

    @Test func nothingShownNothingGivenBack() {
        var claim = CursorClaim<Token>()
        let some = claim.giveBack(current: a, liveResize: false)
        let none = claim.giveBack(current: nil, liveResize: false)
        #expect(!some && !none)
    }

    @Test func theLatestShownCounts() {
        var claim = CursorClaim<Token>()
        claim.show(a)
        claim.show(b)
        #expect(claim.shown === b)
        let given = claim.giveBack(current: b, liveResize: false)
        #expect(given)
    }

    /// Every cursor the picture sets goes through `show`: an earlier one of its own, current
    /// again without that, isn't what the claim holds.
    @Test func onlyTheCursorLastShownIsThePictures() {
        var claim = CursorClaim<Token>()
        claim.show(a)
        claim.show(b)
        let given = claim.giveBack(current: a, liveResize: false)
        #expect(!given)
    }

    /// The arrow isn't the picture's to take back: AppKit and the overlays set the same one.
    @Test func showingNoCursorOfItsOwnEndsTheClaim() {
        var claim = CursorClaim<Token>()
        claim.show(a)
        claim.show(nil)
        #expect(claim.shown == nil)
        let given = claim.giveBack(current: a, liveResize: false)
        #expect(!given)
    }

    /// The edge's cursor belongs to the window during a live resize; the claim waits for after.
    @Test func aLiveResizeKeepsTheClaim() {
        var claim = CursorClaim<Token>()
        claim.show(a)
        let during = claim.giveBack(current: a, liveResize: true)
        #expect(!during)
        let after = claim.giveBack(current: a, liveResize: false)
        #expect(after)
    }

    @Test func aLiveResizeKeepsTheClaimWhateverIsShown() {
        var claim = CursorClaim<Token>()
        claim.show(a)
        let during = claim.giveBack(current: b, liveResize: true)
        #expect(!during)
        #expect(claim.shown === a)
        let after = claim.giveBack(current: b, liveResize: false)
        #expect(!after)
        #expect(claim.shown == nil)
    }

    @Test func aLiveResizeWithNothingShownGivesNothingBack() {
        var claim = CursorClaim<Token>()
        let given = claim.giveBack(current: a, liveResize: true)
        #expect(!given)
    }
}
