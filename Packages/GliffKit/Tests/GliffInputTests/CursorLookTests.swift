import GliffProtocol
import Testing

@testable import GliffInput

/// What the pointer looks like over the picture: the remote's visible shape only while
/// captured; without one, nothing on a headless session (its video carries the pointer), else
/// the arrow.
@Suite struct CursorLookTests {
    private let shape = CursorShape(id: 7, width: 2, height: 2, hotX: 1, hotY: 1, argbLength: 16)
    private var visible: CursorImage {
        CursorImage(
            shape, payload: [0, 0, 255, 255, 255, 255, 255, 255] + [0, 0, 255, 255, 255, 255, 255, 255])!
    }
    private var clear: CursorImage { CursorImage(shape, payload: [UInt8](repeating: 0, count: 16))! }

    @Test func releasedIsAlwaysTheArrow() {
        #expect(
            CursorLook.choose(captured: false, headless: false, image: visible, pointsPerPixel: 0.5) == .arrow
        )
        #expect(
            CursorLook.choose(captured: false, headless: true, image: visible, pointsPerPixel: 0.5) == .arrow)
    }

    /// Upstream `set_remote_cursor`: on a headless session, whose video carries the pointer,
    /// nothing where another session would show the arrow.
    @Test func capturedOnAHeadlessSessionWithoutAShapeToShowIsHidden() {
        #expect(CursorLook.choose(captured: true, headless: true, image: nil, pointsPerPixel: 0.5) == .hidden)
        #expect(
            CursorLook.choose(captured: true, headless: true, image: clear, pointsPerPixel: 0.5) == .hidden)
        #expect(CursorLook.choose(captured: true, headless: true, image: nil, pointsPerPixel: nil) == .hidden)
    }

    /// A visible shape is shown on any session, headless included (upstream shows it first).
    @Test func capturedOnAHeadlessSessionShowsAVisibleShape() {
        #expect(
            CursorLook.choose(captured: true, headless: true, image: visible, pointsPerPixel: 0.5)
                == .shape(visible, pointsPerPixel: 0.5))
    }

    @Test func capturedShowsAVisibleShapeAtItsSize() {
        #expect(
            CursorLook.choose(captured: true, headless: false, image: visible, pointsPerPixel: 0.5)
                == .shape(visible, pointsPerPixel: 0.5))
    }

    /// No shape yet, one that can't be shown or has nothing to show, or no picture to size it
    /// by: the arrow.
    @Test func capturedWithoutAShapeToShowIsTheArrow() {
        #expect(CursorLook.choose(captured: true, headless: false, image: nil, pointsPerPixel: 0.5) == .arrow)
        #expect(
            CursorLook.choose(captured: true, headless: false, image: clear, pointsPerPixel: 0.5) == .arrow)
        #expect(
            CursorLook.choose(captured: true, headless: false, image: visible, pointsPerPixel: nil) == .arrow)
    }
}
