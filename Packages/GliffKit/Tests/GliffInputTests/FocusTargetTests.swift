import Testing

@testable import GliffInput

/// Where a window's activation puts the remote pointer, so the host's focus follows it: the
/// Mac pointer over the picture, else where the remote cursor was, else the centre.
@Suite struct FocusTargetTests {
    private let retina = PictureGeometry(
        streamWidth: 2560, streamHeight: 1440, viewWidth: 2560, viewHeight: 1440, scaleMilli: 2000)
    /// A 2560×1440 output streamed at 1280×720, at scale 1.
    private let downscaled = PictureGeometry(
        streamWidth: 1280, streamHeight: 720, viewWidth: 2560, viewHeight: 1440, scaleMilli: 1000)

    private func at(_ point: (x: Double, y: Double)?, _ x: Double, _ y: Double) -> Bool {
        point.map { $0 == (x, y) } ?? false
    }

    @Test func theMacPointerWins() {
        let target = FocusTarget.target(
            macPointer: (x: 12, y: 34), cursor: (x: 1000, y: 500), geometry: retina)
        #expect(at(target, 12, 34))
    }

    @Test func theCursorIsNext() {
        let cursor = (x: 1000.0, y: 500.0)
        #expect(at(FocusTarget.target(macPointer: nil, cursor: cursor, geometry: retina), 500, 250))
        #expect(at(FocusTarget.target(macPointer: nil, cursor: cursor, geometry: downscaled), 500, 250))
    }

    /// A cursor hidden while typing is still where the person left it, and the host's focus
    /// with it.
    @Test func aHiddenCursorStillCounts() {
        let cursor = (x: 1000.0, y: 500.0)
        #expect(at(FocusTarget.target(macPointer: nil, cursor: cursor, geometry: retina), 500, 250))
    }

    @Test func noCursorGivesTheCentre() {
        #expect(at(FocusTarget.target(macPointer: nil, cursor: nil, geometry: retina), 640, 360))
        #expect(at(FocusTarget.target(macPointer: nil, cursor: nil, geometry: downscaled), 640, 360))
    }

    @Test func aCursorPastTheEdgeIsClamped() {
        #expect(at(FocusTarget.logical(bufferX: 9000, bufferY: 5000, geometry: retina), 1280, 720))
    }

    @Test func aNegativeCursorIsClamped() {
        #expect(at(FocusTarget.logical(bufferX: -5, bufferY: -1, geometry: downscaled), 0, 0))
    }

    /// Before a picture there is nowhere to send the pointer: no nudge.
    @Test func aPictureWithNoSizeGivesNoTarget() {
        let empty = PictureGeometry(
            streamWidth: 0, streamHeight: 0, viewWidth: 0, viewHeight: 0, scaleMilli: 1000)
        #expect(
            FocusTarget.target(macPointer: nil, cursor: (x: 10, y: 10), geometry: empty) == nil
        )
        #expect(FocusTarget.target(macPointer: nil, cursor: nil, geometry: empty) == nil)
    }
}
