import Foundation
import GliffProtocol
import Testing

@testable import GliffSession

/// The `.gliffrec` recording: raw frames from the StreamConfig and first keyframe on.
@Suite struct RecorderTests {
    /// A new, empty directory for one test's recording.
    static func directory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appending(
            path: "glifftop-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private static let config = HandshakeTests.config

    private func frame(_ id: UInt64, keyframe: Bool) -> ServerMessage {
        .videoFrame(
            VideoFrameHeader(
                frameID: id, ptsMicroseconds: 0, isKeyframe: keyframe, damage: [], dataLength: 0, auxLength: 0
            ))
    }

    @Test func fileIsNamedForTheStart() throws {
        let start = try Date("2026-11-19T15:04:05Z", strategy: .iso8601)
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current
        let parts = calendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: start)
        let name = String(
            format: "glifftop-%04d%02d%02d-%02d%02d%02d.gliffrec", parts.year ?? 0, parts.month ?? 0,
            parts.day ?? 0, parts.hour ?? 0, parts.minute ?? 0, parts.second ?? 0)
        let recorder = StreamRecorder(directory: try Self.directory(), duration: .seconds(5), now: start)
        #expect(recorder.fileURL.lastPathComponent == name)
    }

    /// Recording starts at the next keyframe, with the StreamConfig in force before it, and
    /// takes nothing but StreamConfigs and video frames, written as on the wire.
    @Test func startsAtTheNextKeyframe() async throws {
        let recorder = StreamRecorder(directory: try Self.directory(), duration: .seconds(60), now: .now)
        func offer(_ marker: UInt8, _ message: ServerMessage) async -> Bool {
            await recorder.offer(frame: Frame(body: [marker], payload: [marker, marker]), message: message)
        }
        #expect(await offer(0xC0, .streamConfig(Self.config)))
        for id: UInt64 in 1...4 { #expect(await offer(UInt8(id), frame(id, keyframe: false))) }
        #expect(await offer(5, frame(5, keyframe: true)))
        #expect(await offer(0xEE, .ping(t: 1)))
        #expect(await offer(6, frame(6, keyframe: false)))
        await recorder.finish()
        let expected = try [0xC0, 5, 6].flatMap { (marker: UInt8) in
            try Frame.encode(body: [marker], payload: [marker, marker])
        }
        #expect(try Data(contentsOf: recorder.fileURL) == Data(expected))
    }

    /// A recording started mid-stream is handed the StreamConfig in force when it is made.
    @Test func startsWithTheConfigItWasGiven() async throws {
        let config = Frame(body: [0xC0], payload: [0xC0, 0xC0])
        let recorder = StreamRecorder(
            directory: try Self.directory(), duration: .seconds(60), now: .now, config: config)
        #expect(
            await recorder.offer(frame: Frame(body: [5], payload: [5, 5]), message: frame(5, keyframe: true)))
        await recorder.finish()
        let expected = try [0xC0, 5].flatMap { (marker: UInt8) in
            try Frame.encode(body: [marker], payload: [marker, marker])
        }
        #expect(try Data(contentsOf: recorder.fileURL) == Data(expected))
    }

    /// The duration runs from the first keyframe written, not from when recording was asked
    /// for (ssh may take a while to connect).
    @Test func durationRunsFromTheFirstKeyframe() async throws {
        let recorder = StreamRecorder(directory: try Self.directory(), duration: .zero, now: .now)
        #expect(await recorder.offer(frame: Frame(body: [0xC0]), message: .streamConfig(Self.config)))
        #expect(await recorder.offer(frame: Frame(body: [1]), message: frame(1, keyframe: true)) == false)
        let expected = try [0xC0, 1].flatMap { (marker: UInt8) in try Frame.encode(body: [marker]) }
        #expect(try Data(contentsOf: recorder.fileURL) == Data(expected))
    }
}
