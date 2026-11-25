import Testing

@testable import GliffInput

/// Integrated's chrome rule: a ⌘ key-down with the pointer over Glifftop's chrome goes to the
/// Mac, after the host lets go of every key it holds, and its repeats and key-up follow it
/// there; a ⌘ modifier press there isn't sent. Only those events ask where the pointer is.
@Suite struct InputControllerChromeTests {
    /// T: Mac 0x11, evdev 20. A: Mac 0x00, evdev 30.
    private let t: UInt16 = 0x11
    private let a: UInt16 = 0x00
    private let command: MacModifierFlags = [.command, .leftCommand]

    private func captured(_ mode: CaptureMode = .integrated) -> InputController {
        var controller = capturedController()
        _ = controller.capture(.mode(mode))
        return controller
    }

    @Test func aCommandKeyOverTheChromeGoesToTheMac() {
        var controller = captured()
        let result = controller.key(down(t, command), overChrome: { true })
        #expect(!result.consumed)
        #expect(result.messages.isEmpty)
    }

    @Test func heldKeysAreLetGoLastPressedFirst() {
        var controller = captured()
        _ = controller.key(down(a))
        // ⌘ pressed on the picture: Super goes to the host.
        #expect(controller.key(flags(0x37, command), overChrome: { false }).messages == [key(125, true)])
        let result = controller.key(down(t, command), overChrome: { true })
        #expect(!result.consumed)
        #expect(result.messages == [key(125, false), key(30, false)])
    }

    @Test func itsRepeatsAndKeyUpStayWithTheMac() {
        var controller = captured()
        _ = controller.key(down(t, command), overChrome: { true })
        for event in [down(t, command, isRepeat: true), up(t, command)] {
            let result = controller.key(event, overChrome: { false })
            #expect(!result.consumed)
            #expect(result.messages.isEmpty)
        }
        // The hold ended with the key-up: a new press on the picture goes to the host.
        #expect(controller.key(down(t, command), overChrome: { false }).consumed)
    }

    @Test(arguments: [MacModifierFlags(), [.control, .leftControl], [.option, .leftOption]])
    func otherKeysOverTheChromeGoToTheHost(_ flags: MacModifierFlags) {
        var controller = captured()
        var asked = 0
        let result = controller.key(
            down(t, flags),
            overChrome: {
                asked += 1
                return true
            })
        #expect(result.consumed)
        #expect(result.messages.last == key(20, true))
        #expect(asked == 0)
    }

    @Test func aCommandPressOverTheChromeIsNotSent() {
        var controller = captured()
        let press = controller.key(flags(0x37, command), overChrome: { true })
        #expect(!press.consumed)
        #expect(press.messages.isEmpty)
        #expect(
            controller.key(down(a, command), overChrome: { false }).messages == [
                key(125, true), key(30, true),
            ])
    }

    /// A ⌘ press over the chrome sends nothing of its own, but still lets go of a modifier
    /// whose release went missing.
    @Test func aCommandPressOverTheChromeLetsGoOfAStaleModifier() {
        var controller = captured()
        #expect(controller.key(flags(0x3B, [.control, .leftControl])).messages == [key(29, true)])
        let press = controller.key(flags(0x37, command), overChrome: { true })
        #expect(!press.consumed)
        #expect(press.messages == [key(29, false)])
    }

    /// ⌘ went to the Mac over the chrome: a held key's release there goes to the host without
    /// Super; back on the picture, the next one presses Super first.
    @Test func aReleaseOverTheChromeDoesNotPressSuper() {
        var controller = captured()
        _ = controller.key(down(a))
        _ = controller.key(flags(0x38, [.shift, .leftShift]))
        _ = controller.key(flags(0x37, command.union([.shift, .leftShift])), overChrome: { true })
        let shiftUp = controller.key(flags(0x38, command), overChrome: { true })
        #expect(shiftUp.consumed)
        #expect(shiftUp.messages == [key(42, false)])
        #expect(
            controller.key(up(a, command), overChrome: { false }).messages == [
                key(125, true), key(30, false),
            ])
    }

    /// Caps Lock with ⌘ held over the chrome toggles on the host without Super.
    @Test func aToggleOverTheChromeDoesNotPressSuper() {
        var controller = captured()
        let toggle = controller.key(flags(0x39, command.union(.capsLock)), overChrome: { true })
        #expect(toggle.messages == [key(58, true), key(58, false)])
    }

    /// After ⌘ is let go, a chord key's repeats are no shortcut: they go nowhere.
    @Test func aChordKeysPlainRepeatsAreSwallowed() {
        var controller = captured()
        _ = controller.key(down(t, command), overChrome: { true })
        #expect(!controller.key(down(t, command, isRepeat: true)).consumed)
        let plain = controller.key(down(t, isRepeat: true))
        #expect(plain.consumed)
        #expect(plain.messages.isEmpty)
        #expect(!controller.key(up(t)).consumed)
    }

    /// A chord key's repeat or key-up still lets go of a modifier whose release went missing.
    @Test func aChordKeysEventsLetGoOfAStaleModifier() {
        var controller = captured()
        _ = controller.key(down(t, command), overChrome: { true })
        _ = controller.key(flags(0x3B, command.union([.control, .leftControl])), overChrome: { false })
        let repeated = controller.key(down(t, command, isRepeat: true))
        #expect(!repeated.consumed)
        #expect(repeated.messages == [key(29, false)])
    }

    /// A chord key's key-up went to another window as capture fell: once capture is back, its
    /// repeats are no chord's.
    @Test func captureEndingForgetsTheChordKeys() {
        var controller = captured()
        _ = controller.key(down(t, command), overChrome: { true })
        _ = controller.capture(.windowKey(false))
        _ = controller.capture(.windowKey(true))
        #expect(controller.key(down(t, command, isRepeat: true)).consumed)
    }

    @Test func overChromeIsAskedOnlyForCommandEvents() {
        var asked = 0
        let probe = {
            asked += 1
            return false
        }
        var controller = captured()
        _ = controller.key(down(a), overChrome: probe)
        _ = controller.key(down(a, command, isRepeat: true), overChrome: probe)
        _ = controller.key(up(0x01, command), overChrome: probe)
        _ = controller.key(up(a), overChrome: probe)
        _ = controller.key(flags(0x38, [.shift, .leftShift]), overChrome: probe)
        var confined = captured(.confined)
        _ = confined.key(down(t, command), overChrome: probe)
        var released = InputController(keymap: "k1")
        _ = released.key(down(t, command), overChrome: probe)
        #expect(asked == 0)
        _ = controller.key(down(t, command), overChrome: probe)
        #expect(asked == 1)
    }

    @Test func captureSendsCommandChordsToTheHost() {
        var controller = captured(.confined)
        let result = controller.key(down(t, command), overChrome: { true })
        #expect(result.consumed)
        #expect(result.messages == [key(125, true), key(20, true)])
    }

    @Test(arguments: CaptureMode.allCases)
    func shiftEscReleasesInBothModes(_ mode: CaptureMode) {
        var controller = captured(mode)
        let result = controller.key(down(0x35, [.shift, .leftShift]), overChrome: { true })
        #expect(result.consumed)
        #expect(!controller.isCaptured)
    }

    @Test func anUnheldReleasePassesAndAHeldOneIsSent() {
        var controller = captured()
        let unheld = controller.key(up(a))
        #expect(!unheld.consumed)
        #expect(unheld.messages.isEmpty)
        _ = controller.key(down(a))
        let held = controller.key(up(a))
        #expect(held.consumed)
        #expect(held.messages == [key(30, false)])
    }
}
