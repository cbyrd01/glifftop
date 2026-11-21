import Foundation

/// One NV12 picture: Y (`width × height`), then interleaved UV (`width/2 × height/2` pairs).
struct NV12Planes {
    let width: Int
    let height: Int
    let luma: [UInt8]
    let chroma: [UInt8]
}

/// One synthetic picture from `glifftop-fake-server planes`: the Dual420 planes upstream's
/// `split_yuv444` makes, and the BGRA a client must show from them.
struct PlaneSet {
    let name: String
    let main: NV12Planes
    let aux: NV12Planes
    /// Dual420: the full 4:4:4 picture.
    let expected: [UInt8]
    /// Single420: the main plane alone, its chroma copied over each 2×2 block.
    let expectedSingle: [UInt8]
}

enum SyntheticFixtures {
    enum LoadError: Error {
        case badName(String)
        case wrongSize(String)
        case noStream(String)
    }

    /// The two Dual420 planes; Single420 streams are the main plane's.
    enum Plane: String {
        case main
        case aux
    }

    /// Every plane set in the bundle, sorted: "bars-192x108", ….
    static let names: [String] = {
        let urls = Bundle.module.urls(
            forResourcesWithExtension: "nv12", subdirectory: "Fixtures/synthetic/planes")
        return Set((urls ?? []).map { String($0.lastPathComponent.split(separator: ".")[0]) }).sorted()
    }()

    static func planes(_ name: String) throws -> PlaneSet {
        let (width, height) = try size(of: name)
        let pixels = width * height
        func nv12(_ suffix: String) throws -> NV12Planes {
            let bytes = try load("\(name).\(suffix).nv12", count: pixels * 3 / 2)
            return NV12Planes(
                width: width, height: height, luma: Array(bytes[..<pixels]), chroma: Array(bytes[pixels...]))
        }
        return PlaneSet(
            name: name, main: try nv12("main"), aux: try nv12("aux"),
            expected: try load("\(name).bgra", count: pixels * 4),
            expectedSingle: try load("\(name).single.bgra", count: pixels * 4))
    }

    /// The encoded stream for plane set `name` (from
    /// tools/encode-fixtures): one Annex B access unit per frame, frame k shifted left 2k pixels.
    static func stream(_ name: String, plane: Plane) throws -> [[UInt8]] {
        let directory = fixtures.appending(path: "synthetic/streams/\(name)", directoryHint: .isDirectory)
        let files = try FileManager.default.contentsOfDirectory(atPath: directory.path(percentEncoded: false))
            .filter { $0.hasSuffix(".\(plane.rawValue).h264") }.sorted()
        guard !files.isEmpty else { throw LoadError.noStream("\(name) \(plane)") }
        return try files.map { Array(try Data(contentsOf: directory.appending(path: $0))) }
    }

    private static let fixtures = Bundle.module.resourceURL!.appending(
        path: "Fixtures", directoryHint: .isDirectory)

    /// "bars-192x108" → (192, 108).
    private static func size(of name: String) throws -> (Int, Int) {
        let sides = name.split(separator: "-").last?.split(separator: "x").compactMap { Int($0) } ?? []
        guard sides.count == 2 else { throw LoadError.badName(name) }
        return (sides[0], sides[1])
    }

    private static func load(_ file: String, count: Int) throws -> [UInt8] {
        let url = fixtures.appending(path: "synthetic/planes/\(file)")
        let data = try Data(contentsOf: url)
        guard data.count == count else { throw LoadError.wrongSize(file) }
        return Array(data)
    }
}
