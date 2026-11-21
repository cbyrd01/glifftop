import Foundation
import Testing

@testable import GliffProtocol

/// The CBOR body of a golden fixture generated from upstream gliff-proto by tools/fake-server.
func fixture(_ name: String) throws -> [UInt8] {
    let url = Bundle.module.url(forResource: name, withExtension: "cbor", subdirectory: "Fixtures")
    return Array(try Data(contentsOf: #require(url, "missing fixture \(name).cbor")))
}

/// The names of the fixtures whose names start with `prefix`, without `.cbor`.
func fixtureNames(prefix: String) throws -> [String] {
    let urls = try #require(Bundle.module.urls(forResourcesWithExtension: "cbor", subdirectory: "Fixtures"))
    return urls.map { $0.deletingPathExtension().lastPathComponent }.filter { $0.hasPrefix(prefix) }
}

/// Shared by the client and server offer fixtures, as in fixtures.rs.
private let offerMimeTypes = ["text/plain;charset=utf-8", "image/png"]
private let offerFiles = [
    ClipboardFile(path: "Résumé 📄.txt", size: 12, isDirectory: false),
    ClipboardFile(path: "dir", size: 0, isDirectory: true),
]

/// Swift values matching the server cases in tools/fake-server/src/fixtures.rs.
let expectedServerMessages: [String: ServerMessage] = [
    "s00_hello_ack": .helloAck(
        version: 1,
        session: SessionInfo(headless: false, output: "DP-2"),
        outputs: [
            OutputInfo(name: "DP-2", width: 2560, height: 1440, scaleMilli: 1000),
            OutputInfo(name: "DP-3", width: 2560, height: 1440, scaleMilli: 1000),
        ],
        features: []
    ),
    "s01_stream_config_dual": .streamConfig(
        StreamConfig(
            codec: .h264, chroma: .dual420, pipeline: .gpu, width: 2560, height: 1440,
            scaleMilli: 1000, extradata: [0, 0, 0, 1, 0x67, 0x64], auxExtradata: [0, 0, 0, 1, 0x67],
            viewWidth: 2560, viewHeight: 1440, fpsCap: 60)),
    "s01b_stream_config_single": .streamConfig(
        StreamConfig(
            codec: .h264, chroma: .single420, pipeline: nil, width: 1280, height: 720,
            scaleMilli: 500, extradata: [1, 2], auxExtradata: nil,
            viewWidth: 2560, viewHeight: 1440, fpsCap: 30)),
    "s02_video_frame": .videoFrame(
        VideoFrameHeader(
            frameID: 7, ptsMicroseconds: 116_000, isKeyframe: true,
            damage: [Rect(x: 0, y: 0, width: 2560, height: 1440)], dataLength: 9000, auxLength: 9500)),
    "s03_cursor_shape": .cursorShape(
        CursorShape(id: 5, width: 24, height: 24, hotX: 4, hotY: 2, argbLength: 2304)),
    "s04_cursor_pos": .cursorPosition(x: 100.5, y: 200.75, shapeID: 5, visible: true),
    "s05_clipboard_offer": .clipboard(.offer(serial: 3, mimeTypes: offerMimeTypes, files: offerFiles)),
    "s06_clipboard_request": .clipboard(.request(id: 2, serial: 9, item: .file(index: 0))),
    "s07_clipboard_data": .clipboard(.data(id: 2, offset: 0, dataLength: 4096, done: true)),
    "s08_pong": .pong(t: 123_456_789, serverNowMilliseconds: 1_700_000_000_999),
    "s09_error": .error(code: 2, message: "no chroma", version: 1),
    "s09b_error_no_version": .error(code: 256, message: "setup", version: nil),
    "s10_clipboard_ack": .clipboard(.ack(id: 2, received: 4096)),
    "s11_clipboard_abort": .clipboard(.abort(id: 2)),
    "s12_ping": .ping(t: 55),
]

/// Swift values matching the client cases in tools/fake-server/src/fixtures.rs.
let expectedClientMessages: [String: ClientMessage] = [
    "c00_hello": .hello(
        version: 1, keymap: "xkb_keymap {}",
        caps: ClientCaps(
            codecs: [.h264], maxWidth: 5120, maxHeight: 2880, chroma: [.dual420, .single420], features: [])),
    "c00b_hello_features": .hello(
        version: 1, keymap: "xkb",
        caps: ClientCaps(
            codecs: [.h264, .h265], maxWidth: 3840, maxHeight: 2160, chroma: [.single420],
            features: ["audio", "outputs"])),
    "c01_resize": .resize(width: 2560, height: 1440, scale: 2.0),
    "c02_key": .key(keycode: 30, pressed: true),
    "c03_pointer_motion": .pointerMotion(x: 1280.5, y: 720.25),
    "c04_pointer_button": .pointerButton(button: 272, pressed: true),
    "c05_pointer_axis_discrete": .pointerAxis(axis: .vertical, value: -15.0, discrete: -1, stop: false),
    "c05b_pointer_axis_smooth": .pointerAxis(axis: .horizontal, value: 3.25, discrete: nil, stop: true),
    "c06_frame_ack": .frameAck(frameID: 42, decodedAtMilliseconds: 1_700_000_000_123),
    "c07_request_keyframe": .requestKeyframe,
    "c08_clipboard_offer": .clipboard(.offer(serial: 3, mimeTypes: offerMimeTypes, files: offerFiles)),
    "c09_clipboard_request_mime": .clipboard(.request(id: 1, serial: 3, item: .mime("image/png"))),
    "c09b_clipboard_request_file": .clipboard(.request(id: 3, serial: 3, item: .file(index: 1))),
    "c10_clipboard_data": .clipboard(.data(id: 1, offset: 262_144, dataLength: 1024, done: false)),
    "c11_ping": .ping(t: 123_456_789),
    "c12_bye": .bye,
    "c13_clipboard_ack": .clipboard(.ack(id: 1, received: 524_288)),
    "c14_clipboard_abort": .clipboard(.abort(id: 1)),
    "c15_keymap": .keymap("xkb"),
    "c16_pong": .pong(t: 987_654_321),
]

enum HostileOutcome: Sendable {
    case decodes(ServerMessage)
    case fails(ProtocolError)
}

/// The hand-built x_ cases in fixtures.rs: shapes a newer or broken server could send.
let hostileFixtureOutcomes: [String: HostileOutcome] = [
    "x_error_u16_overflow": .fails(.integerOverflow),
    // A newer server's extra field is skipped.
    "x_hello_ack_extra_field": .decodes(expectedServerMessages["s00_hello_ack"] ?? .unknown(variant: -1)),
    "x_stream_config_unknown_chroma": .fails(.unknownEnumValue(type: "ChromaMode", value: 9)),
    // An unknown optional enum value is nil, and the fields after it still line up.
    "x_stream_config_unknown_pipeline": .decodes(
        .streamConfig(
            StreamConfig(
                codec: .h264, chroma: .dual420, pipeline: nil, width: 2560, height: 1440,
                scaleMilli: 1000, extradata: [0, 0, 0, 1, 0x67, 0x64], auxExtradata: [0, 0, 0, 1, 0x67],
                viewWidth: 2560, viewHeight: 1440, fpsCap: 60))),
    "x_unknown_variant": .decodes(.unknown(variant: 99)),
]
