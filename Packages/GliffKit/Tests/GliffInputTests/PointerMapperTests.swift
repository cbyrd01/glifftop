import Testing

@testable import GliffInput

/// A point in the drawn picture to the remote's logical coordinates, as upstream's
/// `to_remote`: undo the fit, stretch the view box to the stream, clamp, divide by the scale.
@Suite struct PointerMapperTests {
    private let qhd = PictureGeometry(
        streamWidth: 2560, streamHeight: 1440, viewWidth: 2560, viewHeight: 1440, scaleMilli: 1000)

    private func remote(
        _ x: Double, _ y: Double, _ rect: PictureRect, _ geometry: PictureGeometry? = nil
    ) -> (x: Double, y: Double)? {
        PointerMapper.remote(x: x, y: y, in: rect, geometry: geometry ?? qhd)
    }

    @Test func oneToOne() throws {
        let point = try #require(remote(100, 50, PictureRect(x: 0, y: 0, width: 2560, height: 1440)))
        #expect(point == (100, 50))
    }

    @Test func scaledDown() throws {
        let point = try #require(remote(640, 360, PictureRect(x: 0, y: 0, width: 1280, height: 720)))
        #expect(point == (1280, 720))
    }

    @Test func letterboxed() throws {
        let point = try #require(remote(640, 450, PictureRect(x: 0, y: 90, width: 1280, height: 720)))
        #expect(point == (1280, 720))
    }

    @Test func aPointInTheBarsClampsToTheEdge() throws {
        let rect = PictureRect(x: 0, y: 90, width: 1280, height: 720)
        let top = try #require(remote(640, 10, rect))
        #expect(top == (1280, 0))
        let left = try #require(remote(-5, 400, rect))
        #expect(left.x == 0)
        let corner = try #require(remote(5000, 5000, rect))
        #expect(corner == (2560, 1440))
    }

    @Test func aStretchedViewBox() throws {
        let geometry = PictureGeometry(
            streamWidth: 1280, streamHeight: 720, viewWidth: 2560, viewHeight: 1440, scaleMilli: 1000)
        let point = try #require(
            remote(2560, 1440, PictureRect(x: 0, y: 0, width: 2560, height: 1440), geometry))
        #expect(point == (1280, 720))
    }

    @Test func scaleMilliDivides() throws {
        var geometry = qhd
        geometry.scaleMilli = 1500
        let point = try #require(
            remote(1500, 750, PictureRect(x: 0, y: 0, width: 2560, height: 1440), geometry))
        #expect(point == (1000, 500))
    }

    @Test func aTinyScaleIsFloored() throws {
        var geometry = qhd
        geometry.scaleMilli = 0
        let point = try #require(remote(1, 1, PictureRect(x: 0, y: 0, width: 2560, height: 1440), geometry))
        #expect(point == (100, 100))
    }

    @Test func zeroSizesGiveNil() {
        let rect = PictureRect(x: 0, y: 0, width: 2560, height: 1440)
        #expect(remote(1, 1, PictureRect(x: 0, y: 0, width: 0, height: 1440)) == nil)
        for geometry in [
            PictureGeometry(
                streamWidth: 0, streamHeight: 1440, viewWidth: 2560, viewHeight: 1440, scaleMilli: 1000),
            PictureGeometry(
                streamWidth: 2560, streamHeight: 1440, viewWidth: 2560, viewHeight: 0, scaleMilli: 1000),
        ] {
            #expect(remote(1, 1, rect, geometry) == nil)
        }
    }

    /// A position that isn't a number never reaches the wire (the clamp lets NaN through).
    @Test func aNonFinitePointGivesNil() {
        let rect = PictureRect(x: 0, y: 0, width: 2560, height: 1440)
        #expect(remote(.nan, 10, rect) == nil)
        #expect(remote(10, .infinity, rect) == nil)
    }
}
