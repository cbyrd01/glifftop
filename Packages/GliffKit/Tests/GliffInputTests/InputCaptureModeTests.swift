import Testing

@testable import GliffInput

/// The two modes: both capture on the same conditions; an open menu holds capture off; in
/// Capture (`.confined`) the pointer is confined once it enters the picture, until capture
/// falls, a suspension, or a mode change. Says when the app activates (a rise of capture not
/// caused by a menu closing or a mode change) and when the hint shows.
@Suite struct InputCaptureModeTests {
    @discardableResult
    private func apply(_ capture: inout InputCapture, _ events: [CaptureEvent]) -> [CaptureChange] {
        events.map { capture.apply($0) }
    }

    private let allHold: [CaptureEvent] = [.windowKey(true), .appActive(true), .picture(true)]

    @Test(arguments: CaptureMode.allCases)
    func bothModesCaptureOnTheSameConditions(_ mode: CaptureMode) {
        let spoilers: [CaptureEvent] = [
            .windowKey(false), .appActive(false), .picture(false), .interrupted(true), .menuOpen(true),
            .release,
        ]
        for spoiler in spoilers {
            var capture = InputCapture(mode: mode)
            apply(&capture, allHold)
            #expect(capture.isCaptured)
            apply(&capture, [spoiler])
            #expect(!capture.isCaptured, "\(spoiler)")
        }
    }

    @Test func anOpenMenuHoldsCaptureOff() {
        var capture = InputCapture()
        apply(&capture, allHold + [.menuOpen(true)])
        #expect(!capture.isCaptured)
        #expect(!capture.clickRecaptures)
        apply(&capture, [.menuOpen(false)])
        #expect(capture.isCaptured)
    }

    @Test func aMenuClosingDoesNotActivate() {
        var capture = InputCapture()
        apply(&capture, allHold + [.menuOpen(true)])
        #expect(capture.apply(.menuOpen(false)).activates == false)
    }

    /// The window came to the front while a menu was open (Window ▸ another tab): the rise at
    /// the menu's close is that window's activation.
    @Test(arguments: [
        [CaptureEvent.windowKey(false), .windowKey(true)], [.interrupted(true), .interrupted(false)],
    ])
    func aRiseHeldOffByAMenuStillActivates(_ during: [CaptureEvent]) {
        var capture = InputCapture()
        apply(&capture, allHold + [.menuOpen(true)] + during)
        #expect(capture.apply(.menuOpen(false)).activates)
    }

    @Test func aWindowKeyedUnderAMenuActivatesAtItsClose() {
        var capture = InputCapture()
        apply(&capture, [.appActive(true), .picture(true), .menuOpen(true), .windowKey(true)])
        #expect(capture.apply(.menuOpen(false)).activates)
    }

    /// A submenu reports its opening again: the menu session goes on, and so does what rose
    /// under it.
    @Test func aSecondOpenKeepsTheRiseUnderTheMenu() {
        var capture = InputCapture()
        apply(
            &capture, [.appActive(true), .picture(true), .menuOpen(true), .windowKey(true), .menuOpen(true)])
        #expect(capture.apply(.menuOpen(false)).activates)
    }

    @Test func aModeChangeKeepsCaptureAndDoesNotActivate() {
        var capture = InputCapture()
        apply(&capture, allHold)
        #expect(capture.apply(.mode(.confined)) == CaptureChange())
        #expect(capture.isCaptured)
        #expect(capture.mode == .confined)
        #expect(capture.apply(.mode(.integrated)).activates == false)
        #expect(capture.isCaptured)
    }

    @Test func aRiseFromTheWindowActivates() {
        var capture = InputCapture()
        #expect(apply(&capture, allHold).map(\.activates) == [false, false, true])
        apply(&capture, [.windowKey(false)])
        #expect(capture.apply(.windowKey(true)).activates)
        #expect(capture.apply(.appActive(true)).activates == false)
    }

    @Test func integratedNeverConfines() {
        var capture = InputCapture()
        apply(&capture, allHold + [.pointerOnPicture(true)])
        #expect(capture.isCaptured)
        #expect(!capture.isConfined)
    }

    @Test func confinementWaitsForThePointer() {
        var capture = InputCapture(mode: .confined)
        apply(&capture, allHold)
        #expect(capture.isCaptured)
        #expect(!capture.isConfined)
        apply(&capture, [.pointerOnPicture(true)])
        #expect(capture.isConfined)
    }

    /// The app reports where the pointer is before the edge it comes with.
    @Test func anEntryReportedBeforeTheRiseConfinesAtTheRise() {
        var capture = InputCapture(mode: .confined)
        apply(&capture, [.appActive(true), .picture(true), .pointerOnPicture(true), .windowKey(true)])
        #expect(capture.isConfined)
    }

    @Test func confinementEndsWithCapture() {
        var capture = InputCapture(mode: .confined)
        apply(&capture, allHold + [.pointerOnPicture(true), .windowKey(false)])
        #expect(!capture.isConfined)
        apply(&capture, [.windowKey(true)])
        #expect(capture.isCaptured)
        #expect(!capture.isConfined)
        apply(&capture, [.pointerOnPicture(true)])
        #expect(capture.isConfined)
    }

    @Test func aSuspensionNeedsANewEntry() {
        var capture = InputCapture(mode: .confined)
        apply(&capture, allHold + [.pointerOnPicture(true), .pointerOnPicture(false)])
        #expect(capture.isCaptured)
        #expect(!capture.isConfined)
        apply(&capture, [.pointerOnPicture(true)])
        #expect(capture.isConfined)
    }

    /// The recapturing click is on the picture: it is the entry.
    @Test func releaseThenARecapturingClickConfines() {
        var capture = InputCapture(mode: .confined)
        apply(&capture, allHold + [.pointerOnPicture(true), .release])
        #expect(!capture.isConfined)
        #expect(capture.apply(.pictureClicked).showHint)
        #expect(capture.isConfined)
    }

    /// A click that can't recapture (a menu holds capture off) is no entry.
    @Test func aClickThatCantRecaptureIsNoEntry() {
        var capture = InputCapture(mode: .confined)
        apply(&capture, allHold + [.release, .menuOpen(true), .pictureClicked, .menuOpen(false)])
        #expect(!capture.isCaptured)
        #expect(!capture.isConfined)
    }

    @Test func aModeChangeNeedsANewEntry() {
        var capture = InputCapture()
        apply(&capture, allHold + [.pointerOnPicture(true), .mode(.confined)])
        #expect(!capture.isConfined)
        apply(&capture, [.pointerOnPicture(true)])
        #expect(capture.isConfined)
        apply(&capture, [.mode(.integrated), .mode(.confined)])
        #expect(!capture.isConfined)
    }

    /// The mode it has already, reported again, changes nothing.
    @Test func theSameModeAgainKeepsConfinement() {
        var capture = InputCapture(mode: .confined)
        apply(&capture, allHold + [.pointerOnPicture(true)])
        #expect(capture.apply(.mode(.confined)) == CaptureChange())
        #expect(capture.isConfined)
    }

    /// A new picture (a new session) needs a new entry, even when it comes while released.
    @Test func aNewPictureNeedsANewEntry() {
        var capture = InputCapture(mode: .confined)
        apply(&capture, allHold + [.release, .pointerOnPicture(true), .picture(false), .picture(true)])
        #expect(capture.isCaptured)
        #expect(!capture.isConfined)
    }

    /// A switch to Integrated while captured shows its hint, unless it has shown for this picture.
    @Test func aSwitchToIntegratedShowsItsHintOnce() {
        var capture = InputCapture(mode: .confined)
        apply(&capture, allHold)
        #expect(capture.apply(.mode(.integrated)).showHint)
        apply(&capture, [.mode(.confined)])
        #expect(capture.apply(.mode(.integrated)).showHint == false)
    }

    @Test func aSwitchWhileReleasedShowsNoHint() {
        var capture = InputCapture(mode: .confined)
        apply(&capture, allHold + [.release])
        #expect(capture.apply(.mode(.integrated)).showHint == false)
    }

    /// Sleep or a lock lets the pointer go, as capture ending does.
    @Test func awayEndsConfinement() {
        var capture = InputCapture(mode: .confined)
        apply(&capture, allHold + [.pointerOnPicture(true), .away])
        #expect(capture.isCaptured)
        #expect(!capture.isConfined)
    }

    @Test func captureHintComesAtConfinement() {
        var capture = InputCapture(mode: .confined)
        #expect(apply(&capture, allHold).map(\.showHint) == [false, false, false])
        #expect(capture.apply(.pointerOnPicture(true)).showHint)
    }

    @Test func captureHintOncePerPictureAndAfterRelease() {
        var capture = InputCapture(mode: .confined)
        apply(&capture, allHold + [.pointerOnPicture(true)])
        #expect(
            apply(&capture, [.pointerOnPicture(false), .pointerOnPicture(true)]).map(\.showHint) == [
                false, false,
            ])
        #expect(
            apply(&capture, [.release, .pictureClicked, .pointerOnPicture(true)]).map(\.showHint) == [
                false, true, false,
            ])
        #expect(
            apply(&capture, [.picture(false), .picture(true), .pointerOnPicture(true)]).map(\.showHint) == [
                false, false, true,
            ])
    }
}
