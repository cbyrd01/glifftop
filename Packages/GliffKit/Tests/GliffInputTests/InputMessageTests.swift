import GliffProtocol
import Testing

@testable import GliffInput

@Suite struct InputMessageTests {
    @Test func mapsToClientMessages() {
        #expect(InputMessage.key(code: 30, pressed: true).clientMessage == .key(keycode: 30, pressed: true))
        #expect(InputMessage.key(code: 30, pressed: false).clientMessage == .key(keycode: 30, pressed: false))
        #expect(InputMessage.keymap("x").clientMessage == .keymap("x"))
    }

    @Test func pointerMessagesMapToTheirClientMessages() {
        #expect(InputMessage.pointerMotion(x: 1.5, y: 2).clientMessage == .pointerMotion(x: 1.5, y: 2))
        #expect(
            InputMessage.pointerButton(code: 0x110, pressed: true).clientMessage
                == .pointerButton(button: 0x110, pressed: true))
        #expect(
            InputMessage.pointerAxis(axis: .vertical, value: -15, discrete: -1, stop: false).clientMessage
                == .pointerAxis(axis: .vertical, value: -15, discrete: -1, stop: false))
    }
}
