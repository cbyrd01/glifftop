import Testing

@testable import GliffInput

/// `NSEvent.buttonNumber` to evdev buttons: left, right, middle, back, forward, and on to
/// `BTN_TASK` (upstream's `BTN_LEFT + n` for the extra buttons).
@Suite struct PointerButtonsTests {
    @Test func theFiveButtons() {
        let codes = (0...4).map { PointerButtons.code(forButtonNumber: $0) }
        #expect(codes == [0x110, 0x111, 0x112, 0x113, 0x114])
    }

    @Test func theExtraButtons() {
        #expect(PointerButtons.code(forButtonNumber: 5) == 0x115)
        #expect(PointerButtons.code(forButtonNumber: 7) == 0x117)
    }

    @Test func otherButtonsSendNothing() {
        #expect(PointerButtons.code(forButtonNumber: 8) == nil)
        #expect(PointerButtons.code(forButtonNumber: -1) == nil)
    }
}
