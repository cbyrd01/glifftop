import Foundation
import Testing

@testable import FixtureEncoding

/// Each test gets its own temporary folder, removed when the test ends.
final class StreamFilesTests {
    static let unit = AccessUnit(units: [[0x41, 0x9A]])
    static let idr = AccessUnit(units: [[0x67, 1], [0x68, 2], [0x65, 3]])

    private let scratch: URL

    init() throws {
        scratch = FileManager.default.temporaryDirectory.appending(path: "encode-fixtures-\(UUID())")
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
    }

    deinit {
        try? FileManager.default.removeItem(at: scratch)
    }

    /// A folder holding anything but stream folders is refused, and nothing in it is touched.
    @Test func refusesAFolderThatIsNotStreams() throws {
        let root = scratch
        let note = root.appending(path: "notes.md")
        try Data("keep".utf8).write(to: note)
        #expect(throws: StreamFiles.NotAStreamsFolder.self) {
            try StreamFiles.replace(
                in: root, with: [EncodedStream(name: "a-2x2", plane: "main", units: [Self.idr])])
        }
        #expect(FileManager.default.fileExists(atPath: note.path(percentEncoded: false)))
    }

    /// Old streams (a removed plane set, a longer stream) are gone after a replace.
    @Test func replacesOldStreamsEntirely() throws {
        let root = scratch
        for path in ["gone-2x2/000.main.h264", "a-2x2/008.aux.h264"] {
            let file = root.appending(path: path)
            try FileManager.default.createDirectory(
                at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data([1]).write(to: file)
        }
        try StreamFiles.replace(
            in: root, with: [EncodedStream(name: "a-2x2", plane: "aux", units: [Self.idr, Self.unit])])
        #expect(try Self.listing(root) == ["a-2x2/000.aux.h264", "a-2x2/001.aux.h264"])
        #expect(
            try Data(contentsOf: root.appending(path: "a-2x2/001.aux.h264"))
                == Data([0, 0, 0, 1, 0x41, 0x9A]))
    }

    @Test func createsAMissingFolder() throws {
        let root = scratch.appending(path: "streams")
        try StreamFiles.replace(
            in: root, with: [EncodedStream(name: "a-2x2", plane: "main", units: [Self.idr])])
        #expect(try Self.listing(root) == ["a-2x2/000.main.h264"])
    }

    /// Only upstream's shape is written: [SPS, PPS, IDR], then one P slice per frame.
    @Test func refusesTheWrongShape() throws {
        for (index, units) in [
            [Self.unit], [Self.idr, Self.idr], [Self.idr, AccessUnit(units: [[0x41, 1], [0x41, 2]])], [],
        ].enumerated() {
            let root = scratch.appending(path: "\(index)")
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            #expect(throws: StreamFiles.WrongShape.self) {
                try StreamFiles.replace(
                    in: root, with: [EncodedStream(name: "a-2x2", plane: "main", units: units)])
            }
            #expect(try Self.listing(root).isEmpty)
        }
    }

    private static func listing(_ root: URL) throws -> [String] {
        let enumerator = FileManager.default.enumerator(atPath: root.path(percentEncoded: false))
        return (enumerator?.allObjects as? [String] ?? []).filter { $0.hasSuffix(".h264") }.sorted()
    }
}
