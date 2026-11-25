import GliffProtocol
import Testing

@testable import GliffInput

/// What the pointer looks like over the picture: the remote's visible shape only while
/// captured; without one, nothing when the video carries the pointer, else the arrow.
@Suite struct CursorLookTests {
    private let shape = CursorShape(id: 7, width: 2, height: 2, hotX: 1, hotY: 1, argbLength: 16)
    private var visible: CursorImage {
        CursorImage(
            shape, payload: [0, 0, 255, 255, 255, 255, 255, 255] + [0, 0, 255, 255, 255, 255, 255, 255])!
    }
    private var clear: CursorImage { CursorImage(shape, payload: [UInt8](repeating: 0, count: 16))! }

    /// Confined, the Mac cursor stays put: the app draws the virtual pointer instead.
    @Test(arguments: [false, true])
    func confinedHidesTheMacCursor(_ videoHasPointer: Bool) {
        #expect(
            CursorLook.choose(
                captured: true, videoHasPointer: videoHasPointer, image: visible, pointsPerPixel: 0.5,
                confined: true) == .hidden)
    }

    @Test func releasedIsAlwaysTheArrow() {
        #expect(
            CursorLook.choose(captured: false, videoHasPointer: false, image: visible, pointsPerPixel: 0.5)
                == .arrow
        )
        #expect(
            CursorLook.choose(captured: false, videoHasPointer: true, image: visible, pointsPerPixel: 0.5)
                == .arrow)
    }

    /// Upstream `set_remote_cursor`: when the video carries the pointer, nothing where another
    /// session would show the arrow.
    @Test func capturedOverAPointerInTheVideoWithoutAShapeToShowIsHidden() {
        #expect(
            CursorLook.choose(captured: true, videoHasPointer: true, image: nil, pointsPerPixel: 0.5)
                == .hidden)
        #expect(
            CursorLook.choose(captured: true, videoHasPointer: true, image: clear, pointsPerPixel: 0.5)
                == .hidden)
        #expect(
            CursorLook.choose(captured: true, videoHasPointer: true, image: nil, pointsPerPixel: nil)
                == .hidden)
    }

    /// A visible shape is shown on any session, one whose video carries the pointer included
    /// (upstream shows it first).
    @Test func capturedOverAPointerInTheVideoShowsAVisibleShape() {
        #expect(
            CursorLook.choose(captured: true, videoHasPointer: true, image: visible, pointsPerPixel: 0.5)
                == .shape(visible, pointsPerPixel: 0.5))
    }

    @Test func capturedShowsAVisibleShapeAtItsSize() {
        #expect(
            CursorLook.choose(captured: true, videoHasPointer: false, image: visible, pointsPerPixel: 0.5)
                == .shape(visible, pointsPerPixel: 0.5))
    }

    /// No shape yet, one that can't be shown or has nothing to show, or no picture to size it
    /// by: the arrow.
    @Test func capturedWithoutAShapeToShowIsTheArrow() {
        #expect(
            CursorLook.choose(captured: true, videoHasPointer: false, image: nil, pointsPerPixel: 0.5)
                == .arrow)
        #expect(
            CursorLook.choose(captured: true, videoHasPointer: false, image: clear, pointsPerPixel: 0.5)
                == .arrow)
        #expect(
            CursorLook.choose(captured: true, videoHasPointer: false, image: visible, pointsPerPixel: nil)
                == .arrow)
    }

    /// A virtual screen's video carries the host's pointer, as does a monitor of Hyprland's
    /// headless backend (a host with no display, such as a container): its cursor is drawn
    /// into the picture. A real monitor's isn't.
    @Test(arguments: [
        (true, "gliff-2413057", true), (false, "HEADLESS-1", true), (false, "HEADLESS-12", true),
        (false, "gliff-1234", true), (false, "gliff-display", false), (false, "DP-3", false),
        (false, "HDMI-A-1", false), (false, "headless-1", false),
        (false, "HEADLESS", false),
    ])
    func theVideoCarriesThePointer(headless: Bool, output: String, carries: Bool) {
        #expect(
            CursorLook.videoHasPointer(SessionInfo(headless: headless, output: output)) == carries)
    }

    @Test func noSessionYetHasNoPointerInItsVideo() {
        #expect(!CursorLook.videoHasPointer(nil))
    }
}
