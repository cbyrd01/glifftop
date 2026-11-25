import Testing

@testable import GliffInput

/// A ⌘ chord's key that went to the Mac keeps its repeats and key-up there, until its key-up.
@Suite struct MacChordKeysTests {
    private let t: UInt16 = 0x11
    private let command: MacModifierFlags = [.command, .leftCommand]

    /// `take`'s answers for `events`, in order, after holding T.
    private func takes(_ events: [MacKeyEvent]) -> [Bool] {
        var keys = MacChordKeys()
        keys.hold(t)
        return events.map { keys.take($0) }
    }

    @Test func aHeldKeysRepeatAndKeyUpAreTaken() {
        #expect(takes([down(t, command, isRepeat: true), up(t)]) == [true, true])
    }

    @Test func theKeyUpEndsTheHold() {
        #expect(takes([up(t, command), down(t, command, isRepeat: true), up(t)]) == [true, false, false])
    }

    /// A fresh press of a held key (its key-up went elsewhere) is routed anew, and ends the hold.
    @Test func aFreshPressIsNotTaken() {
        #expect(takes([down(t, command), up(t)]) == [false, false])
    }

    @Test func otherKeysAreNotTaken() {
        #expect(
            takes([down(0x00, command, isRepeat: true), up(0x00), flags(0x37), up(t)]) == [
                false, false, false, true,
            ])
    }
}
