import Testing

@testable import GliffInput

/// Input (keys and pointer) goes to the remote while the window is key, the app active, the
/// picture showing, the link live and no popover over it, unless Shift+Esc released it (until
/// the picture is clicked).
@Suite struct InputCaptureTests {
    /// Applies `events` in order; the hint answers, in order.
    @discardableResult
    private func apply(_ capture: inout InputCapture, _ events: [CaptureEvent]) -> [Bool] {
        events.map { capture.apply($0).showHint }
    }

    private let allHold: [CaptureEvent] = [.windowKey(true), .appActive(true), .picture(true)]

    @Test func capturedOnlyWhenAllHold() {
        let spoilers: [CaptureEvent] = [
            .windowKey(false), .appActive(false), .picture(false), .interrupted(true), .popover(true),
        ]
        for spoiler in spoilers {
            var capture = InputCapture()
            apply(&capture, allHold)
            #expect(capture.isCaptured)
            apply(&capture, [spoiler])
            #expect(!capture.isCaptured, "\(spoiler)")
        }
        var capture = InputCapture()
        apply(&capture, [.windowKey(true), .appActive(true)])
        #expect(!capture.isCaptured)
    }

    /// Released by Shift+Esc, in the background too, until a click on the picture or a new
    /// picture.
    @Test func releasedUntilClickedOrANewPicture() {
        var capture = InputCapture()
        apply(&capture, allHold + [.release, .windowKey(false)])
        #expect(capture.isReleased)
        apply(&capture, [.windowKey(true), .pictureClicked])
        #expect(!capture.isReleased)
        apply(&capture, [.release, .picture(false), .picture(true)])
        #expect(!capture.isReleased)
        var controller = InputController(keymap: "")
        for event in allHold + [.release] { _ = controller.capture(event) }
        #expect(controller.isReleased)
    }

    @Test func shiftEscHoldsUntilClicked() {
        var capture = InputCapture()
        apply(&capture, allHold + [.release])
        #expect(!capture.isCaptured)
        apply(&capture, [.windowKey(false), .windowKey(true)])
        #expect(!capture.isCaptured)
        apply(&capture, [.pictureClicked])
        #expect(capture.isCaptured)
    }

    @Test func aNewPictureStartsCaptured() {
        var capture = InputCapture()
        apply(&capture, allHold + [.release, .picture(false), .picture(true)])
        #expect(capture.isCaptured)
    }

    @Test func interruptionEndsAndResumes() {
        var capture = InputCapture()
        apply(&capture, allHold + [.interrupted(true), .interrupted(false)])
        #expect(capture.isCaptured)
    }

    @Test func hintOnFirstCaptureAndAfterRelease() {
        var capture = InputCapture()
        #expect(apply(&capture, allHold) == [false, false, true])
        #expect(apply(&capture, [.windowKey(false), .windowKey(true)]) == [false, false])
        #expect(apply(&capture, [.release, .pictureClicked]) == [false, true])
    }

    @Test func aNewPictureShowsTheHintAgain() {
        var capture = InputCapture()
        apply(&capture, allHold)
        #expect(apply(&capture, [.picture(false), .picture(true)]) == [false, true])
    }

    /// The source window of Show All Monitors key again after a new window took key: captured,
    /// with no activation (the host's focus never left its screen).
    @Test func aQuietRiseDoesNotActivate() {
        var capture = InputCapture()
        apply(&capture, allHold + [.windowKey(false)])
        #expect(!capture.apply(.windowKey(true), quiet: true).activates)
        #expect(capture.isCaptured)
        apply(&capture, [.windowKey(false)])
        #expect(capture.apply(.windowKey(true)).activates)
    }

    /// A quiet rise under an open menu: the menu's close is no activation either.
    @Test func aQuietRiseUnderAMenuStaysQuiet() {
        var capture = InputCapture()
        apply(&capture, allHold + [.windowKey(false), .menuOpen(true)])
        _ = capture.apply(.windowKey(true), quiet: true)
        #expect(!capture.apply(.menuOpen(false)).activates)
        #expect(capture.isCaptured)
    }

    /// A quiet rise under the Ports popover: its close is no activation either.
    @Test func aQuietRiseUnderThePopoverStaysQuiet() {
        var capture = InputCapture()
        apply(&capture, allHold + [.windowKey(false), .popover(true)])
        _ = capture.apply(.windowKey(true), quiet: true)
        #expect(!capture.apply(.popover(false)).activates)
        #expect(capture.isCaptured)
    }

    @Test func awayKeepsCapture() {
        var capture = InputCapture()
        apply(&capture, allHold + [.away])
        #expect(capture.isCaptured)
    }

    /// A click takes input back only when Shift+Esc's release alone holds it off: one while
    /// the link is interrupted leaves the release standing.
    @Test func aClickThatCantRecaptureLeavesTheRelease() {
        var capture = InputCapture()
        apply(&capture, allHold + [.release, .interrupted(true), .pictureClicked, .interrupted(false)])
        #expect(!capture.isCaptured)
    }

    /// A popover over the window takes the keys while it is open; capture comes back after,
    /// without the hint.
    @Test func aPopoverTakesTheKeys() {
        var capture = InputCapture()
        #expect(
            apply(&capture, allHold + [.popover(true), .popover(false)]) == [
                false, false, true, false, false,
            ])
        #expect(capture.isCaptured)
    }

    /// Like a menu's close: the window stayed key under the popover, and the host's focus with
    /// it.
    @Test func aPopoverClosingDoesNotActivate() {
        var capture = InputCapture()
        apply(&capture, allHold + [.popover(true)])
        #expect(capture.apply(.popover(false)).activates == false)
    }

    /// The window came to the front again while the popover was open: the rise at its close is
    /// that window's activation.
    @Test(arguments: [
        [CaptureEvent.windowKey(false), .windowKey(true)], [.appActive(false), .appActive(true)],
    ])
    func aRiseHeldOffByAPopoverStillActivates(_ during: [CaptureEvent]) {
        var capture = InputCapture()
        apply(&capture, allHold + [.popover(true)] + during)
        #expect(capture.apply(.popover(false)).activates)
    }

    /// A menu opened and closed over the popover: capture stays off until the popover closes,
    /// and that close is no activation.
    @Test func aMenuOverThePopoverKeepsItsCloseQuiet() {
        var capture = InputCapture()
        apply(&capture, allHold + [.popover(true), .menuOpen(true)])
        #expect(capture.apply(.menuOpen(false)) == CaptureChange())
        #expect(!capture.isCaptured)
        #expect(capture.apply(.popover(false)).activates == false)
        #expect(capture.isCaptured)
    }

    /// Release Input still has something to release under the popover, as under a menu.
    @Test func thePopoverLeavesInputReleasable() {
        var capture = InputCapture()
        apply(&capture, allHold + [.popover(true)])
        #expect(!capture.isCaptured)
        #expect(capture.isReleasable)
    }
}
