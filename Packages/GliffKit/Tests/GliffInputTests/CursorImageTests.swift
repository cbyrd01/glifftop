import GliffProtocol
import Testing

@testable import GliffInput

/// A remote cursor shape, checked as upstream's `remote_cursor` does, but strictly:
/// sides 1–1024, the payload exactly `width × height × 4` BGRA bytes, the hotspot inside.
/// A valid shape with nothing to show (all clear, or one colour) is kept, not visible.
@Suite struct CursorImageTests {
    private let red: [UInt8] = [0, 0, 255, 255]
    private let white: [UInt8] = [255, 255, 255, 255]

    private func shape(
        id: UInt32 = 7, width: UInt32 = 2, height: UInt32 = 2, hot: (Int32, Int32) = (1, 1),
        length: UInt32? = nil
    ) -> CursorShape {
        CursorShape(
            id: id, width: width, height: height, hotX: hot.0, hotY: hot.1,
            argbLength: length ?? width * height * 4)
    }

    private var pixels: [UInt8] { red + white + red + white }

    @Test func aGoodShape() throws {
        let image = try #require(CursorImage(shape(), payload: pixels))
        #expect(image.id == 7 && image.width == 2 && image.height == 2)
        #expect(image.hotX == 1 && image.hotY == 1)
        #expect(image.bgra == pixels)
        #expect(image.isVisible)
    }

    @Test func zeroOrOversizedSidesAreRefused() {
        #expect(CursorImage(shape(width: 0), payload: []) == nil)
        #expect(CursorImage(shape(height: 0), payload: []) == nil)
        let wide = shape(width: 1025, height: 1)
        #expect(CursorImage(wide, payload: [UInt8](repeating: 255, count: 1025 * 4)) == nil)
    }

    @Test func aLengthMismatchIsRefused() {
        #expect(CursorImage(shape(length: 15), payload: Array(pixels.dropLast())) == nil)
        #expect(CursorImage(shape(), payload: Array(pixels.dropLast())) == nil)
        #expect(CursorImage(shape(), payload: pixels + [0]) == nil)
    }

    @Test func aHotspotOutsideIsRefused() {
        #expect(CursorImage(shape(hot: (-1, 0)), payload: pixels) == nil)
        #expect(CursorImage(shape(hot: (0, -1)), payload: pixels) == nil)
        #expect(CursorImage(shape(hot: (2, 0)), payload: pixels) == nil)
        #expect(CursorImage(shape(hot: (0, 2)), payload: pixels) == nil)
    }

    @Test func anInvisibleShapeIsValidButNotVisible() throws {
        let clear = try #require(CursorImage(shape(), payload: [UInt8](repeating: 0, count: 16)))
        #expect(!clear.isVisible)
        let flat = try #require(CursorImage(shape(), payload: red + red + red + red))
        #expect(!flat.isVisible)
        let faint = try #require(
            CursorImage(shape(), payload: [0, 0, 0, 0] + [0, 0, 0, 0] + [0, 0, 0, 0] + [0, 0, 0, 1]))
        #expect(faint.isVisible)
    }

    /// Cursor pixels are remote view pixels: on screen they take the picture's scale.
    @Test func pointsPerPixel() {
        #expect(CursorImage.pointsPerPixel(rectWidth: 1280, viewWidth: 2560, backingScale: 2) == 0.25)
        #expect(CursorImage.pointsPerPixel(rectWidth: 2560, viewWidth: 2560, backingScale: 2) == 0.5)
    }

    /// No picture yet, or a window with no screen: no size, rather than infinity or NaN.
    @Test func noPointsPerPixelWithoutSizes() {
        #expect(CursorImage.pointsPerPixel(rectWidth: 0, viewWidth: 2560, backingScale: 2) == nil)
        #expect(CursorImage.pointsPerPixel(rectWidth: 1280, viewWidth: 0, backingScale: 2) == nil)
        #expect(CursorImage.pointsPerPixel(rectWidth: 1280, viewWidth: 2560, backingScale: 0) == nil)
        #expect(CursorImage.pointsPerPixel(rectWidth: .nan, viewWidth: 2560, backingScale: 2) == nil)
    }
}
