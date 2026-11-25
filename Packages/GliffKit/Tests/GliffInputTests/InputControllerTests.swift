import Testing

@testable import GliffInput

/// The rules the app drives: capture, translation and the ledger together. Captured keys are
/// always swallowed; every way capture ends lets go of what the remote holds.
@Suite struct InputControllerTests {
    private typealias Flags = MacModifierFlags

    private func captured() -> InputController { capturedController() }

    @Test func notCapturedPassesThrough() {
        var controller = InputController(keymap: "k1")
        let result = controller.key(down(0x00))
        #expect(!result.consumed)
        #expect(result.messages.isEmpty)
    }

    @Test func chordIsSent() {
        var controller = captured()
        #expect(controller.key(flags(0x37, [.command, .leftCommand])).messages == [key(125, true)])
        #expect(controller.key(down(0x0D, [.command, .leftCommand])).messages == [key(17, true)])
    }

    @Test func resigningKeyReleasesTheChord() {
        var controller = captured()
        _ = controller.key(flags(0x37, [.command, .leftCommand]))
        _ = controller.key(down(0x0D, [.command, .leftCommand]))
        let result = controller.capture(.windowKey(false))
        #expect(result.messages == [key(17, false), key(125, false)])
        #expect(!controller.isCaptured)
    }

    @Test func keyUpWithoutPressIsDropped() {
        var controller = InputController(keymap: "k1")
        #expect(!controller.key(flags(0x37, [.command, .leftCommand])).consumed)
        for event: CaptureEvent in [.windowKey(true), .appActive(true), .picture(true)] {
            _ = controller.capture(event)
        }
        let result = controller.key(flags(0x37))
        #expect(result.consumed)
        #expect(result.messages.isEmpty)
    }

    @Test func shiftEscReleasesAndNeverSendsEsc() {
        var controller = captured()
        #expect(controller.key(flags(0x38, [.shift, .leftShift])).messages == [key(42, true)])
        let release = controller.key(down(0x35, [.shift, .leftShift]))
        #expect(release.consumed)
        #expect(release.messages == [key(42, false)])
        #expect(!controller.isCaptured)
        // Esc stays away from the Mac until it comes up: its repeats and its key-up.
        #expect(controller.key(down(0x35, [.shift, .leftShift], isRepeat: true)).consumed)
        #expect(controller.key(up(0x35, [.shift, .leftShift])).consumed)
        #expect(!controller.key(flags(0x38)).consumed)
        #expect(!controller.key(down(0x35)).consumed)
    }

    /// ⌘Tab back with ⌘ still down: the press went to the Mac, so the next key brings it.
    @Test func aModifierHeldBeforeCaptureJoinsTheNextKey() {
        var controller = InputController(keymap: "k1")
        #expect(!controller.key(flags(0x37, [.command, .leftCommand])).consumed)
        for event: CaptureEvent in [.windowKey(true), .appActive(true), .picture(true)] {
            _ = controller.capture(event)
        }
        #expect(
            controller.key(down(0x0D, [.command, .leftCommand])).messages == [key(125, true), key(17, true)])
        #expect(controller.key(flags(0x37)).messages == [key(125, false)])
    }

    /// A modifier's release that never arrived: the next key, without its flag, lets go of it.
    @Test func aMissedModifierReleaseIsCaught() {
        var controller = captured()
        _ = controller.key(flags(0x37, [.command, .leftCommand]))
        #expect(controller.key(down(0x0D)).messages == [key(125, false), key(17, true)])
    }

    /// An event with only the shared bit (as software can post): one side is pressed, not both,
    /// so the modifier's own release leaves nothing held.
    @Test func aSharedBitAloneHoldsOneSide() {
        var controller = captured()
        #expect(controller.key(down(0x0D, [.command])).messages == [key(125, true), key(17, true)])
        _ = controller.key(up(0x0D, [.command]))
        #expect(controller.key(flags(0x37)).messages == [key(125, false)])
    }

    /// With only the shared bit, the side the remote already holds stays the one held.
    @Test func aSharedBitAloneKeepsTheHeldSide() {
        var controller = captured()
        #expect(controller.key(flags(0x36, [.command, .rightCommand])).messages == [key(126, true)])
        #expect(controller.key(down(0x0D, [.command])).messages == [key(17, true)])
    }

    /// A modifier whose key-up never came is let go by the next event that says it is up, a
    /// modifier change or a key-up included, not only by the next key-down.
    @Test func aStaleModifierIsReleasedByAnyEvent() {
        var controller = captured()
        _ = controller.key(flags(0x37, [.command, .leftCommand]))
        #expect(
            controller.key(flags(0x38, [.shift, .leftShift])).messages == [key(125, false), key(42, true)])
        var other = captured()
        _ = other.key(down(0x0D))
        _ = other.key(flags(0x37, [.command, .leftCommand]))
        #expect(other.key(up(0x0D)).messages == [key(125, false), key(17, false)])
    }

    /// Esc's key-up after Shift+Esc went elsewhere: a fresh Esc press is not swallowed.
    @Test func aFreshEscAfterAMissedKeyUpIsSent() {
        var controller = captured()
        _ = controller.key(down(0x35, [.shift, .leftShift]))
        _ = controller.capture(.pictureClicked)
        #expect(controller.key(down(0x35)).messages == [key(1, true)])
    }

    @Test func capsLockTogglesWithoutHolding() {
        var controller = captured()
        #expect(controller.key(flags(0x39, [.capsLock])).messages == [key(58, true), key(58, false)])
        #expect(controller.capture(.windowKey(false)).messages.isEmpty)
    }

    @Test func capturedKeysAreConsumedEvenWhenNothingIsSent() {
        var controller = captured()
        for event in [flags(0x3F, [.function]), down(0x7F), down(0x00, isRepeat: true)] {
            let result = controller.key(event)
            #expect(result.consumed)
            #expect(result.messages.isEmpty)
        }
    }

    @Test func interruptionReleasesEverything() {
        var controller = captured()
        _ = controller.key(down(0x00))
        #expect(controller.capture(.interrupted(true)).messages == [key(30, false)])
    }

    @Test func awayReleasesButKeepsCapture() {
        var controller = captured()
        _ = controller.key(down(0x00))
        #expect(controller.capture(.away).messages == [key(30, false)])
        #expect(controller.isCaptured)
    }

    @Test func theHintComesWithCapture() {
        var controller = InputController(keymap: "k1")
        _ = controller.capture(.windowKey(true))
        _ = controller.capture(.appActive(true))
        #expect(controller.capture(.picture(true)).showHint)
        #expect(controller.key(down(0x35, [.shift, .leftShift])).showHint == false)
        #expect(controller.capture(.pictureClicked).showHint)
    }

    @Test func sameKeymapIsNotResent() {
        var controller = InputController(keymap: "k1")
        #expect(controller.keymap("k1") == nil)
        #expect(controller.keymap("k2") == .keymap("k2"))
        #expect(controller.keymap("k2") == nil)
        #expect(controller.keymap("") == nil)
    }

    // MARK: The focus nudge

    @Test func activationSendsTwoMotionsOnePixelApart() {
        var controller = captured()
        #expect(
            controller.activate(at: (x: 100, y: 50)).messages == [
                .pointerMotion(x: 99, y: 50), .pointerMotion(x: 100, y: 50),
            ])
        #expect(
            controller.activate(at: (x: 0.5, y: 7)).messages == [
                .pointerMotion(x: 1.5, y: 7), .pointerMotion(x: 0.5, y: 7),
            ])
    }

    @Test func noNudgeWithoutCapture() {
        var controller = InputController(keymap: "k1")
        #expect(controller.activate(at: (x: 100, y: 50)).messages.isEmpty)
    }

    @Test func aClickAfterActivationAtTheSamePlaceSendsNoMotion() throws {
        var controller = captured()
        _ = controller.activate(at: (x: 100, y: 50))
        let left = try #require(PointerButtons.code(forButtonNumber: 0))
        let click = controller.pointer(.button(number: 0, pressed: true, x: 100, y: 50, flags: 0))
        #expect(click.messages == [.pointerButton(code: left, pressed: true)])
    }

    @Test func anOpenMenuLetsGoOfEverything() {
        var controller = captured()
        _ = controller.key(down(0x00))
        _ = controller.pointer(.button(number: 0, pressed: true, x: 1, y: 2, flags: 0))
        let result = controller.capture(.menuOpen(true))
        #expect(result.messages == [.pointerButton(code: 272, pressed: false), key(30, false)])
        #expect(!controller.isCaptured)
        #expect(controller.key(down(0x00)).consumed == false)
    }

    @Test func theResultSaysWhenToActivate() {
        var controller = captured()
        _ = controller.capture(.windowKey(false))
        let result = controller.capture(.windowKey(true))
        #expect(result.activates)
        #expect(controller.capture(.menuOpen(true)).activates == false)
        #expect(controller.capture(.menuOpen(false)).activates == false)
    }

    @Test func theModeAndConfinementShowThrough() {
        var controller = InputController(mode: .confined, keymap: "k1")
        for event: CaptureEvent in [.windowKey(true), .appActive(true), .picture(true)] {
            _ = controller.capture(event)
        }
        #expect(controller.mode == .confined)
        #expect(!controller.isConfined)
        _ = controller.capture(.pointerOnPicture(true))
        #expect(controller.isConfined)
        _ = controller.capture(.mode(.integrated))
        #expect(controller.mode == .integrated)
        #expect(!controller.isConfined)
    }
}
