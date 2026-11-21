import Testing

@testable import GliffInput

/// Mode A: input (keys and pointer) goes to the remote while the window is key, the app active, the
/// picture showing and the link live, unless Shift+Esc released it (until the picture is
/// clicked).
@Suite struct InputCaptureTests {
    /// Applies `events` in order; the hint answers, in order.
    @discardableResult
    private func apply(_ capture: inout InputCapture, _ events: [CaptureEvent]) -> [Bool] {
        events.map { capture.apply($0) }
    }

    private let allHold: [CaptureEvent] = [.windowKey(true), .appActive(true), .picture(true)]

    @Test func capturedOnlyWhenAllHold() {
        let spoilers: [CaptureEvent] = [
            .windowKey(false), .appActive(false), .picture(false), .interrupted(true),
        ]
        for spoiler in spoilers {
            var capture = InputCapture(mode: .windowInFront)
            apply(&capture, allHold)
            #expect(capture.isCaptured)
            apply(&capture, [spoiler])
            #expect(!capture.isCaptured, "\(spoiler)")
        }
        var capture = InputCapture(mode: .windowInFront)
        apply(&capture, [.windowKey(true), .appActive(true)])
        #expect(!capture.isCaptured)
    }

    @Test func shiftEscHoldsUntilClicked() {
        var capture = InputCapture(mode: .windowInFront)
        apply(&capture, allHold + [.release])
        #expect(!capture.isCaptured)
        apply(&capture, [.windowKey(false), .windowKey(true)])
        #expect(!capture.isCaptured)
        apply(&capture, [.pictureClicked])
        #expect(capture.isCaptured)
    }

    @Test func aNewPictureStartsCaptured() {
        var capture = InputCapture(mode: .windowInFront)
        apply(&capture, allHold + [.release, .picture(false), .picture(true)])
        #expect(capture.isCaptured)
    }

    @Test func interruptionEndsAndResumes() {
        var capture = InputCapture(mode: .windowInFront)
        apply(&capture, allHold + [.interrupted(true), .interrupted(false)])
        #expect(capture.isCaptured)
    }

    @Test func hintOnFirstCaptureAndAfterRelease() {
        var capture = InputCapture(mode: .windowInFront)
        #expect(apply(&capture, allHold) == [false, false, true])
        #expect(apply(&capture, [.windowKey(false), .windowKey(true)]) == [false, false])
        #expect(apply(&capture, [.release, .pictureClicked]) == [false, true])
    }

    @Test func aNewPictureShowsTheHintAgain() {
        var capture = InputCapture(mode: .windowInFront)
        apply(&capture, allHold)
        #expect(apply(&capture, [.picture(false), .picture(true)]) == [false, true])
    }

    @Test func awayKeepsCapture() {
        var capture = InputCapture(mode: .windowInFront)
        apply(&capture, allHold + [.away])
        #expect(capture.isCaptured)
    }

    /// A click takes input back only when Shift+Esc's release alone holds it off: one while
    /// the link is interrupted leaves the release standing.
    @Test func aClickThatCantRecaptureLeavesTheRelease() {
        var capture = InputCapture(mode: .windowInFront)
        apply(&capture, allHold + [.release, .interrupted(true), .pictureClicked, .interrupted(false)])
        #expect(!capture.isCaptured)
    }
}
