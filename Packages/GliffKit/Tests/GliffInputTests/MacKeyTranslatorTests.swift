import Testing

@testable import GliffInput

/// One Mac key event, as plain values, to what it means for the remote. Stateless: the
/// ledger and capture decide what is actually sent.
@Suite struct MacKeyTranslatorTests {
    private typealias Flags = MacModifierFlags

    private func action(_ code: UInt16, _ kind: MacKeyEvent.Kind, _ flags: Flags = []) -> KeyAction {
        MacKeyTranslator.action(for: MacKeyEvent(keyCode: code, kind: kind, flags: flags.rawValue))
    }

    @Test func keyDownAndUp() {
        #expect(action(0x00, .down(isRepeat: false)) == .press(30))
        #expect(action(0x00, .up) == .release(30))
    }

    @Test func repeatsAreIgnored() {
        #expect(action(0x00, .down(isRepeat: true)) == .ignore)
    }

    @Test func modifiersReadTheirOwnDeviceBit() {
        #expect(action(0x37, .flagsChanged, [.command, .leftCommand]) == .press(125))
        #expect(action(0x36, .flagsChanged, [.command, .rightCommand]) == .press(126))
        // Left still held, right let go: the shared ⌘ bit stays set.
        #expect(action(0x36, .flagsChanged, [.command, .leftCommand]) == .release(126))
        #expect(action(0x3D, .flagsChanged, [.option, .leftOption]) == .release(100))
        #expect(action(0x3B, .flagsChanged, [.control, .leftControl]) == .press(29))
        #expect(action(0x3E, .flagsChanged, [.control, .rightControl]) == .press(97))
        #expect(action(0x38, .flagsChanged, [.shift, .leftShift]) == .press(42))
        #expect(action(0x3C, .flagsChanged, [.shift, .rightShift]) == .press(54))
        #expect(action(0x3A, .flagsChanged, [.option, .leftOption]) == .press(56))
        #expect(action(0x3D, .flagsChanged, [.option, .rightOption]) == .press(100))
    }

    /// Events posted by software can carry only the shared bit: no left or right bit for that
    /// modifier means the shared one decides. A shared bit cleared is a release whatever the
    /// device bits say.
    @Test func withoutDeviceBitsTheSharedBitDecides() {
        #expect(action(0x38, .flagsChanged, [.shift]) == .press(42))
        #expect(action(0x37, .flagsChanged, [.command]) == .press(125))
        #expect(action(0x38, .flagsChanged, [.leftShift]) == .release(42))
        // The other side's bit present: this side's own bit decides.
        #expect(action(0x38, .flagsChanged, [.shift, .rightShift]) == .release(42))
    }

    @Test func capsLockToggles() {
        #expect(action(0x39, .flagsChanged, [.capsLock]) == .toggle(58))
        #expect(action(0x39, .flagsChanged) == .toggle(58))
    }

    @Test func fnAndUnmappedAreIgnored() {
        #expect(action(0x3F, .flagsChanged, [.function]) == .ignore)
        #expect(action(0x7F, .down(isRepeat: false)) == .ignore)
        #expect(action(0x7F, .up) == .ignore)
    }

    @Test func shiftEscReleases() {
        #expect(action(0x35, .down(isRepeat: false), [.shift, .leftShift]) == .releaseKeyboard)
        #expect(action(0x35, .down(isRepeat: false), [.shift, .rightShift]) == .releaseKeyboard)
        // Caps Lock doesn't count as another modifier.
        #expect(action(0x35, .down(isRepeat: false), [.shift, .leftShift, .capsLock]) == .releaseKeyboard)
    }

    @Test func shiftEscWithOtherModifiersIsSent() {
        #expect(
            action(0x35, .down(isRepeat: false), [.shift, .leftShift, .command, .leftCommand]) == .press(1))
        #expect(
            action(0x35, .down(isRepeat: false), [.shift, .leftShift, .option, .leftOption]) == .press(1))
        #expect(
            action(0x35, .down(isRepeat: false), [.shift, .leftShift, .control, .leftControl]) == .press(1))
    }

    @Test func plainEscIsSent() {
        #expect(action(0x35, .down(isRepeat: false)) == .press(1))
        #expect(action(0x35, .up, [.shift]) == .release(1))
    }
}
