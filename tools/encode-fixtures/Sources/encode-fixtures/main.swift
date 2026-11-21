import FixtureEncoding
import Foundation

// encode-fixtures <planes dir> <streams dir>: encodes every `<name>.main.nv12`/`.aux.nv12`
// pair into streams/<name>/NNN.{main,aux}.h264, frames shifted left 2 pixels at a time.

/// GliffVideoTests expects this many frames per stream.
let frameCount = 8

func report(_ line: String) {
    FileHandle.standardError.write(Data((line + "\n").utf8))
}

let arguments = CommandLine.arguments.dropFirst()
guard arguments.count == 2, let planesPath = arguments.first, let streamsPath = arguments.last else {
    report("usage: encode-fixtures <planes dir> <streams dir>")
    exit(2)
}
let planes = URL(filePath: planesPath, directoryHint: .isDirectory)
let streams = URL(filePath: streamsPath, directoryHint: .isDirectory)

do {
    let names = try FileManager.default.contentsOfDirectory(atPath: planes.path(percentEncoded: false))
        .filter { $0.hasSuffix(".main.nv12") }.map { String($0.dropLast(".main.nv12".count)) }.sorted()
    guard !names.isEmpty else { throw CocoaError(.fileNoSuchFile) }
    var encoded: [EncodedStream] = []
    for name in names {
        let sides = name.split(separator: "-").last?.split(separator: "x").compactMap { Int($0) } ?? []
        guard sides.count == 2 else { throw CocoaError(.fileReadInvalidFileName) }
        for plane in ["main", "aux"] {
            let source = try NV12(
                contentsOf: planes.appending(path: "\(name).\(plane).nv12"), width: sides[0], height: sides[1]
            )
            let units = try H264Encoder.encode((0..<frameCount).map { source.shiftedLeft(by: $0) })
            encoded.append(EncodedStream(name: name, plane: plane, units: units))
            report("\(name) \(plane): \(units.map { $0.types.map(String.init).joined(separator: " ") })")
        }
    }
    // Everything is encoded and checked before anything is replaced.
    try StreamFiles.replace(in: streams, with: encoded)
    report(
        "wrote \(encoded.count) streams (\(names.count) plane sets) to \(streams.path(percentEncoded: false))"
    )
} catch {
    report("encode-fixtures: \(error)")
    exit(1)
}
