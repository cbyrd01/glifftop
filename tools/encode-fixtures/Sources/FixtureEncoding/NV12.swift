public import Foundation

/// One NV12 picture: Y (`width × height`), then interleaved UV (`width/2 × height/2` pairs), as
/// `glifftop-fake-server planes` writes them.
public struct NV12: Equatable, Sendable {
    public let width: Int
    public let height: Int
    public let luma: [UInt8]
    public let chroma: [UInt8]

    public struct WrongSize: Error {}

    /// Planes of exactly `width × height` luma and half as much chroma; sides positive and even.
    public init(width: Int, height: Int, luma: [UInt8], chroma: [UInt8]) throws(WrongSize) {
        guard width > 0, height > 0, width % 2 == 0, height % 2 == 0, luma.count == width * height,
            chroma.count == width * height / 2
        else { throw WrongSize() }
        self.init(unchecked: width, height, luma, chroma)
    }

    private init(unchecked width: Int, _ height: Int, _ luma: [UInt8], _ chroma: [UInt8]) {
        self.width = width
        self.height = height
        self.luma = luma
        self.chroma = chroma
    }

    /// Reads `<W>x<H>`-sized planes from `url`.
    public init(contentsOf url: URL, width: Int, height: Int) throws {
        let bytes = [UInt8](try Data(contentsOf: url))
        guard bytes.count == width * height * 3 / 2 else { throw WrongSize() }
        try self.init(
            width: width, height: height, luma: Array(bytes[..<(width * height)]),
            chroma: Array(bytes[(width * height)...]))
    }

    /// The picture moved left by `2 × steps` luma pixels (`steps` chroma pairs; negative moves
    /// right), wrapping, so
    /// every frame of a test stream differs and still has a known expected picture.
    public func shiftedLeft(by steps: Int) -> NV12 {
        NV12(
            unchecked: width, height, Self.rotateRows(luma, rowLength: width, by: 2 * steps),
            Self.rotateRows(chroma, rowLength: width, by: 2 * steps))
    }

    private static func rotateRows(_ bytes: [UInt8], rowLength: Int, by offset: Int) -> [UInt8] {
        stride(from: 0, to: bytes.count, by: rowLength).flatMap { start in
            let row = bytes[start..<start + rowLength]
            let split = row.startIndex + (offset % rowLength + rowLength) % rowLength
            return Array(row[split...] + row[..<split])
        }
    }
}
