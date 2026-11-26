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
    /// A drawn picture: where it is, and what it shows.
    struct Picture: Sendable, CustomTestStringConvertible {
        var name: String
        var rect: PictureRect
        var geometry: PictureGeometry
        var testDescription: String { name }
    }

    static let pictures = [
        Picture(
            name: "letterboxed", rect: PictureRect(x: 0, y: 90, width: 1280, height: 720),
            geometry: PictureGeometry(
                streamWidth: 2560, streamHeight: 1440, viewWidth: 2560, viewHeight: 1440, scaleMilli: 1000)),
        Picture(
            name: "scale 2", rect: PictureRect(x: 0, y: 0, width: 2560, height: 1440),
            geometry: PictureGeometry(
                streamWidth: 2560, streamHeight: 1440, viewWidth: 2560, viewHeight: 1440, scaleMilli: 2000)),
        Picture(
            name: "stretched view box", rect: PictureRect(x: 40, y: 0, width: 1200, height: 800),
            geometry: PictureGeometry(
                streamWidth: 1280, streamHeight: 720, viewWidth: 2560, viewHeight: 1440, scaleMilli: 1500)),
    ]

    @Test(arguments: pictures)
    func localInvertsRemote(_ picture: Picture) throws {
        for (x, y) in [(0.0, 0.0), (100.5, 37.25), (600, 400)] {
            let local = try #require(
                PointerMapper.local(x: x, y: y, in: picture.rect, geometry: picture.geometry))
            let back = try #require(
                PointerMapper.remote(x: local.x, y: local.y, in: picture.rect, geometry: picture.geometry))
            #expect(abs(back.x - x) < 1e-9 && abs(back.y - y) < 1e-9, "\(x), \(y)")
        }
    }

    @Test(arguments: pictures)
    func remoteDeltaIsTheDifferenceOfTwoPoints(_ picture: Picture) throws {
        let (rect, geometry) = (picture.rect, picture.geometry)
        let start = (x: rect.x + 100, y: rect.y + 50)
        let (dx, dy) = (13.5, -7.0)
        let a = try #require(PointerMapper.remote(x: start.x, y: start.y, in: rect, geometry: geometry))
        let b = try #require(
            PointerMapper.remote(x: start.x + dx, y: start.y + dy, in: rect, geometry: geometry))
        let delta = try #require(PointerMapper.remoteDelta(dx: dx, dy: dy, in: rect, geometry: geometry))
        #expect(abs(delta.dx - (b.x - a.x)) < 1e-9)
        #expect(abs(delta.dy - (b.y - a.y)) < 1e-9)
    }

    @Test func noDeltaWithoutAPicture() {
        let empty = PictureRect(x: 0, y: 0, width: 0, height: 0)
        #expect(PointerMapper.remoteDelta(dx: 1, dy: 1, in: empty, geometry: qhd) == nil)
        #expect(PointerMapper.local(x: 1, y: 1, in: empty, geometry: qhd) == nil)
        let rect = PictureRect(x: 0, y: 0, width: 100, height: 100)
        #expect(PointerMapper.remoteDelta(dx: .nan, dy: 1, in: rect, geometry: qhd) == nil)
    }
}
