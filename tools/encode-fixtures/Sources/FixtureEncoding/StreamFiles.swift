public import Foundation

/// One encoded stream: plane set `name`, plane "main" or "aux".
public struct EncodedStream: Sendable {
    public let name: String
    public let plane: String
    public let units: [AccessUnit]

    public init(name: String, plane: String, units: [AccessUnit]) {
        self.name = name
        self.plane = plane
        self.units = units
    }
}

/// Writes streams as `<root>/<name>/NNN.<plane>.h264`, one Annex B access unit per file.
public enum StreamFiles {
    public struct NotAStreamsFolder: Error, CustomStringConvertible {
        public let description: String
    }

    public struct WrongShape: Error, CustomStringConvertible {
        public let description: String
    }

    /// Replaces everything in `root` with `streams`. Every stream must have upstream's shape
    /// (`[SPS, PPS, IDR]`, then one P slice per frame), and `root` must hold only stream
    /// folders: both are checked before anything is deleted.
    public static func replace(in root: URL, with streams: [EncodedStream]) throws {
        for stream in streams {
            let types = stream.units.map(\.types)
            guard types.first == [7, 8, 5], types.dropFirst().allSatisfy({ $0 == [1] }) else {
                throw WrongShape(description: "\(stream.name) \(stream.plane): NAL types \(types)")
            }
        }
        let manager = FileManager.default
        let old = try streamFolders(in: root)
        for folder in old { try manager.removeItem(at: folder) }
        for stream in streams {
            let folder = root.appending(path: stream.name, directoryHint: .isDirectory)
            try manager.createDirectory(at: folder, withIntermediateDirectories: true)
            for (index, unit) in stream.units.enumerated() {
                let file = String(format: "%03d.%@.h264", index, stream.plane)
                try Data(unit.annexB).write(to: folder.appending(path: file))
            }
        }
    }

    /// The folders in `root` (none if it doesn't exist yet); throws if anything in it isn't a
    /// folder of `NNN.main.h264`/`NNN.aux.h264` files.
    private static func streamFolders(in root: URL) throws -> [URL] {
        let manager = FileManager.default
        guard manager.fileExists(atPath: root.path(percentEncoded: false)) else { return [] }
        return try manager.contentsOfDirectory(atPath: root.path(percentEncoded: false))
            .filter { $0 != ".DS_Store" }
            .map { name in
                let folder = root.appending(path: name)
                let files = try? manager.contentsOfDirectory(atPath: folder.path(percentEncoded: false))
                guard let files, files.allSatisfy(isStreamFile) else {
                    throw NotAStreamsFolder(
                        description:
                            "\(folder.path(percentEncoded: false)) isn't a stream folder; nothing was changed"
                    )
                }
                return folder
            }
    }

    private static func isStreamFile(_ name: String) -> Bool {
        name == ".DS_Store" || name.wholeMatch(of: /[0-9]{3}\.(main|aux)\.h264/) != nil
    }
}
