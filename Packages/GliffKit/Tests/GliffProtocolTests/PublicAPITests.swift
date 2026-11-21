import GliffProtocol
import Testing

// No @testable here: this file sees only the public API, as GliffSession and GliffClipboard
// will. Each public value type must be constructible from outside the module.
@Suite struct PublicAPITests {
    @Test func publicTypesHavePublicInitializers() {
        let caps = ClientCaps(
            codecs: [.h264], maxWidth: 5120, maxHeight: 2880, chroma: [.dual420], features: [])
        let file = ClipboardFile(path: "a.txt", size: 1, isDirectory: false)
        let output = OutputInfo(name: "DP-2", width: 2560, height: 1440, scaleMilli: 1000)
        let session = SessionInfo(headless: false, output: "DP-2")
        let rect = Rect(x: 0, y: 0, width: 1, height: 1)
        let config = StreamConfig(
            codec: .h264, chroma: .dual420, pipeline: nil, width: 1, height: 1, scaleMilli: 1000,
            extradata: [], auxExtradata: nil, viewWidth: 1, viewHeight: 1, fpsCap: 60)
        let frame = VideoFrameHeader(
            frameID: 1, ptsMicroseconds: 0, isKeyframe: true, damage: [rect], dataLength: 0, auxLength: 0)
        let shape = CursorShape(id: 1, width: 1, height: 1, hotX: 0, hotY: 0, argbLength: 4)
        #expect(caps.maxWidth == 5120)
        #expect(file.path == "a.txt")
        #expect(output.name == session.output)
        #expect(config.fpsCap == 60)
        #expect(frame.damage == [rect])
        #expect(shape.argbLength == 4)
    }

    @Test func clientMessagesEncodeThroughThePublicAPI() {
        let messages: [ClientMessage] = [
            .hello(
                version: 1, keymap: "xkb",
                caps: ClientCaps(codecs: [.h264], maxWidth: 1, maxHeight: 1, chroma: [], features: [])),
            .pointerAxis(axis: .vertical, value: 1, discrete: nil, stop: false),
            .clipboard(.request(id: 1, serial: 1, item: .file(index: 0))),
            .clipboard(
                .offer(
                    serial: 1, mimeTypes: [], files: [ClipboardFile(path: "a", size: 0, isDirectory: false)])),
        ]
        for message in messages { #expect(!message.encoded.isEmpty) }
    }
}
