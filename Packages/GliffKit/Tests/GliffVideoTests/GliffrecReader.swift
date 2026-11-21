import Foundation
import GliffProtocol

/// One recorded video frame, its payload split as the session splits it.
struct RecordedFrame {
    let header: VideoFrameHeader
    let main: ArraySlice<UInt8>
    let aux: ArraySlice<UInt8>
}

/// A StreamConfig and the video frames that followed it.
struct RecordedSegment {
    let config: StreamConfig
    var frames: [RecordedFrame]
}

/// Reads a `.gliffrec` as `StreamRecorder` writes it: wire frames, a StreamConfig first, then
/// video frames (payload: the main access unit, then the aux one), with a further StreamConfig
/// wherever the stream changed while recording. Other messages are skipped, as the session does.
enum GliffrecReader {
    enum ReadError: Error {
        case noConfig
        case trailingBytes(Int)
    }

    static func read(_ url: URL) throws -> [RecordedSegment] {
        try read(bytes: [UInt8](try Data(contentsOf: url)))
    }

    static func read(bytes: [UInt8]) throws -> [RecordedSegment] {
        var parser = FrameParser()
        parser.append(bytes)
        var segments: [RecordedSegment] = []
        while let frame = try parser.next() {
            let message = try ServerMessage.decode(frame.body)
            try message.checkPayload(carried: frame.payload.count)
            switch message {
            case .streamConfig(let config):
                segments.append(RecordedSegment(config: config, frames: []))
            case .videoFrame(let header):
                guard !segments.isEmpty else { throw ReadError.noConfig }
                let main = Int(header.dataLength)
                let aux = main + Int(header.auxLength)
                segments[segments.count - 1].frames.append(
                    RecordedFrame(
                        header: header, main: frame.payload[..<main], aux: frame.payload[main..<aux]))
            default:
                continue
            }
        }
        guard parser.bufferedByteCount == 0 else { throw ReadError.trailingBytes(parser.bufferedByteCount) }
        guard !segments.isEmpty else { throw ReadError.noConfig }
        return segments
    }
}
