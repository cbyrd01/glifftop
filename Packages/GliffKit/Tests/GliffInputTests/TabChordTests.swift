import Testing

@testable import GliffInput

/// ⌘⇧[ and ⌘⇧] stay with Glifftop while captured: they move between its tabs and windows.
@Suite struct TabChordTests {
    private typealias Flags = MacModifierFlags
    private let commandShift: Flags = [.command, .shift, .leftCommand, .leftShift]

    private func event(_ code: UInt16, _ kind: MacKeyEvent.Kind, _ flags: Flags) -> MacKeyEvent {
        MacKeyEvent(keyCode: code, kind: kind, flags: flags.rawValue)
    }

    @Test func tabChords() {
        #expect(TabChord(event(30, .down(isRepeat: false), commandShift)) == .next)
        #expect(TabChord(event(33, .down(isRepeat: false), commandShift)) == .previous)
        // Held down, it moves once: its repeats are swallowed (`TabChordKeys`).
        #expect(TabChord(event(30, .down(isRepeat: true), commandShift)) == nil)
        #expect(TabChord(event(30, .down(isRepeat: false), [.command, .leftCommand])) == nil)
        #expect(
            TabChord(event(30, .down(isRepeat: false), commandShift.union([.option, .leftOption]))) == nil)
        #expect(
            TabChord(event(30, .down(isRepeat: false), commandShift.union([.control, .leftControl]))) == nil)
        #expect(TabChord(event(30, .up, commandShift)) == nil)
        #expect(TabChord(event(31, .down(isRepeat: false), commandShift)) == nil)
    }

    /// The chord's repeats and key-up are swallowed with it, whatever is still held by then.
    @Test func theChordsUpAndRepeatsAreItsToo() {
        var keys = TabChordKeys()
        #expect(keys.take(event(30, .down(isRepeat: false), commandShift)) == .chord(.next))
        #expect(keys.take(event(30, .down(isRepeat: true), commandShift)) == .swallowed)
        #expect(keys.take(event(30, .up, [.command, .leftCommand])) == .swallowed)
        #expect(keys.take(event(30, .up, commandShift)) == .passed)
    }

    /// A bracket pressed before ⌘⇧ went to the remote: its release must reach it too.
    @Test func aBracketHeldBeforeTheChordIsReleasedToTheRemote() {
        var keys = TabChordKeys()
        #expect(keys.take(event(30, .down(isRepeat: false), [])) == .passed)
        #expect(keys.take(event(30, .down(isRepeat: true), commandShift)) == .passed)
        #expect(keys.take(event(30, .up, commandShift)) == .passed)
    }

    /// The chord moved to another window, which saw its key-up: a later press of that key here
    /// is the remote's, and so is its release.
    @Test func aPressAfterAMissedUpIsTheRemotes() {
        var keys = TabChordKeys()
        #expect(keys.take(event(30, .down(isRepeat: false), commandShift)) == .chord(.next))
        #expect(keys.take(event(30, .down(isRepeat: false), [])) == .passed)
        #expect(keys.take(event(30, .up, [])) == .passed)
    }

    @Test func otherKeysPass() {
        var keys = TabChordKeys()
        #expect(keys.take(event(31, .down(isRepeat: false), commandShift)) == .passed)
        #expect(keys.take(event(56, .flagsChanged, commandShift)) == .passed)
    }
}
