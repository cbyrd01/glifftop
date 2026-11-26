import GliffProtocol
import Testing

@testable import GliffInput

/// Held modifiers join every click, scroll and key: before one goes to the host, the
/// modifiers its flags hold that the host lacks are pressed, and those the host holds that the
/// flags say are up are let go, wherever they were pressed.
@Suite struct InputControllerModifierTests {
    private typealias Flags = MacModifierFlags

    /// One input event, for the balance check.
    enum Step: Sendable, CustomTestStringConvertible {
        case key(MacKeyEvent)
        case pointer(PointerEvent)

        var testDescription: String {
            switch self {
            case .key(let event): "key \(event.keyCode) \(event.kind) \(event.flags)"
            case .pointer(let event): "pointer \(event)"
            }
        }
    }

    private static let command: Flags = [.command, .leftCommand]
    private static let shift: Flags = [.shift, .leftShift]

    private static func click(_ pressed: Bool, _ flags: Flags = [], at x: Double = 10) -> PointerEvent {
        .button(number: 0, pressed: pressed, x: x, y: 20, flags: flags.rawValue)
    }

    private static func scroll(_ flags: Flags = []) -> PointerEvent {
        .scroll(
            ScrollEvent(deltaX: 0, deltaY: 2, isPrecise: false, phase: .none, isMomentum: false), x: 10,
            y: 20,
            flags: flags.rawValue)
    }

    private func captured() -> InputController { capturedController() }

    @Test func aClickWithCommandPressesSuperFirst() {
        var controller = captured()
        let messages = controller.pointer(Self.click(true, Self.command)).messages
        #expect(
            messages == [
                key(125, true), .pointerMotion(x: 10, y: 20), .pointerButton(code: 272, pressed: true),
            ])
    }

    /// Super's release may trigger a binding that moves the host's pointer: the motion is sent
    /// again before the button.
    @Test func aReleaseAfterCommandWentUpReleasesSuperFirst() {
        var controller = captured()
        _ = controller.pointer(Self.click(true, Self.command))
        #expect(
            controller.pointer(Self.click(false)).messages == [
                key(125, false), .pointerMotion(x: 10, y: 20), .pointerButton(code: 272, pressed: false),
            ])
    }

    @Test func aScrollWithShiftPressesShift() {
        var controller = captured()
        let messages = controller.pointer(Self.scroll(Self.shift)).messages
        #expect(messages.prefix(2) == [key(42, true), .pointerMotion(x: 10, y: 20)])
        #expect(messages.count == 3)
    }

    @Test func shiftWhileCommandIsHeldPressesSuperThenShift() {
        var controller = captured()
        #expect(
            controller.key(flags(0x38, Self.command.union(Self.shift))).messages == [
                key(125, true), key(42, true),
            ])
    }

    @Test func rightCommandPressesRightSuper() {
        var controller = captured()
        let messages = controller.pointer(Self.click(true, [.command, .rightCommand])).messages
        #expect(messages.first == key(126, true))
        #expect(!messages.contains(key(125, true)))
    }

    @Test func motionNeverSyncs() {
        var controller = captured()
        _ = controller.key(flags(0x37, Self.command))
        #expect(controller.pointer(.moved(x: 5, y: 6)).messages == [.pointerMotion(x: 5, y: 6)])
    }

    /// Every captured key lets go of a modifier whose release went missing, even one that sends
    /// nothing itself: a repeat, Fn, a key with no evdev code, or the release of a key it lacks
    /// (which goes on to the Mac, where its press went).
    @Test(arguments: [down(0x00, isRepeat: true), flags(0x3F), down(0x3F), up(0x00)])
    func aKeyThatSendsNothingStillLetsGoOfAStaleModifier(_ event: MacKeyEvent) {
        var controller = captured()
        _ = controller.key(flags(0x37, Self.command))
        let result = controller.key(event)
        #expect(result.consumed == (event.kind != .up))
        #expect(result.messages == [key(125, false)])
    }

    /// A posted event can carry only the shared ⌘ bit: right ⌘'s own press presses right Super
    /// alone.
    @Test func aPostedRightCommandPressesOnlyRightSuper() {
        var controller = captured()
        #expect(controller.key(flags(0x36, [.command])).messages == [key(126, true)])
    }

    @Test func aRepeatSyncsNothing() {
        var controller = captured()
        #expect(controller.key(down(0x00, Self.command, isRepeat: true)).messages.isEmpty)
    }

    static let sequences: [[Step]] = [
        // ⌘ pressed, a ⌘-click, ⌘ up, a plain click.
        [
            .key(flags(0x37, command)), .pointer(click(true, command)), .pointer(click(false, command)),
            .key(flags(0x37)), .pointer(click(true)), .pointer(click(false)),
        ],
        // A ⌘-click with no ⌘ key seen, a ⇧-scroll, ⌘⇧A, A up with nothing held, ⌘'s unheld release.
        [
            .pointer(click(true, command)), .pointer(scroll(shift)),
            .key(down(0x00, command.union(shift))), .key(up(0x00)), .pointer(click(false)),
            .key(flags(0x37)),
        ],
        // ⇧ pressed while ⌘ is held off the host, ⇧ up, right ⌘ on a key, a release with nothing.
        [
            .key(flags(0x38, command.union(shift))), .key(flags(0x38, command)),
            .key(down(0x00, [.command, .rightCommand])), .key(up(0x00, [.command, .rightCommand])),
            .pointer(click(true)), .pointer(click(false)),
        ],
        // A repeat with ⌘, motion, Caps Lock with ⌘, a held click through a capture change.
        [
            .key(down(0x00, command, isRepeat: true)), .pointer(.moved(x: 1, y: 1)),
            .key(flags(0x39, command.union(.capsLock))), .pointer(click(true, shift)),
            .key(down(0x0D, shift)),
        ],
    ]

    /// No code pressed twice without a release, no release of what isn't held, and everything
    /// let go by the end.
    @Test(arguments: InputControllerModifierTests.sequences)
    func theLedgerStaysBalanced(_ events: [Step]) {
        var controller = captured()
        var messages: [InputMessage] = []
        for event in events {
            switch event {
            case .key(let key): messages += controller.key(key).messages
            case .pointer(let pointer): messages += controller.pointer(pointer).messages
            }
        }
        messages += controller.capture(.interrupted(true)).messages
        var keys: Set<UInt32> = []
        var buttons: Set<UInt32> = []
        for message in messages {
            switch message {
            case .key(let code, let pressed):
                #expect(pressed ? keys.insert(code).inserted : keys.remove(code) != nil, "key \(code)")
            case .pointerButton(let code, let pressed):
                #expect(
                    pressed ? buttons.insert(code).inserted : buttons.remove(code) != nil, "button \(code)")
            default: break
            }
        }
        #expect(keys.isEmpty)
        #expect(buttons.isEmpty)
    }
}
