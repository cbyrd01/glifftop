import Foundation
import GliffProtocol
import Testing

struct GliffrecReaderTests {
    /// StreamRecorder writes each StreamConfig that arrives while recording (a resize, say), and
    /// the reader skips messages other than video, as the session does.
    @Test func eachStreamConfigStartsASegment() throws {
        let video = try Self.golden("s02_video_frame")
        guard case .videoFrame(let header) = try ServerMessage.decode(video) else {
            Issue.record("s02 is not a VideoFrame")
            return
        }
        let payload = [UInt8](repeating: 0, count: Int(header.dataLength) + Int(header.auxLength))
        let bytes =
            try Frame.encode(body: try Self.golden("s01_stream_config_dual"))
            + Frame.encode(body: video, payload: payload)
            + Frame.encode(body: try Self.golden("s04_cursor_pos"))
            + Frame.encode(body: try Self.golden("s01b_stream_config_single"))
            + Frame.encode(body: video, payload: payload)
            + Frame.encode(body: video, payload: payload)
        let segments = try GliffrecReader.read(bytes: bytes)
        #expect(segments.map(\.config.chroma) == [.dual420, .single420])
        #expect(segments.map(\.frames.count) == [1, 2])
        #expect(segments[0].frames[0].main.count == Int(header.dataLength))
        #expect(segments[0].frames[0].aux.count == Int(header.auxLength))
    }

    /// Upstream's golden message bodies, from GliffProtocolTests' fixtures.
    private static func golden(_ name: String) throws -> [UInt8] {
        let tests = URL(filePath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        return [UInt8](
            try Data(contentsOf: tests.appending(path: "GliffProtocolTests/Fixtures/\(name).cbor")))
    }
}
