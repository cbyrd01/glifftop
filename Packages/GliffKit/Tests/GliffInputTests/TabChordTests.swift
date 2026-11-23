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
        // Held down, it moves once: its repeats are swallowed (`isChordKey`).
        #expect(TabChord(event(30, .down(isRepeat: true), commandShift)) == nil)
        #expect(TabChord(event(30, .down(isRepeat: false), [.command, .leftCommand])) == nil)
        #expect(
            TabChord(event(30, .down(isRepeat: false), commandShift.union([.option, .leftOption]))) == nil)
        #expect(
            TabChord(event(30, .down(isRepeat: false), commandShift.union([.control, .leftControl]))) == nil)
        #expect(TabChord(event(30, .up, commandShift)) == nil)
        #expect(TabChord(event(31, .down(isRepeat: false), commandShift)) == nil)
    }

    @Test func theChordsUpAndRepeatsAreItsToo() {
        #expect(TabChord.isChordKey(event(30, .up, commandShift)))
        #expect(TabChord.isChordKey(event(33, .down(isRepeat: true), commandShift)))
        #expect(!TabChord.isChordKey(event(30, .up, [.command, .leftCommand])))
        #expect(!TabChord.isChordKey(event(30, .down(isRepeat: false), commandShift)))
        #expect(!TabChord.isChordKey(event(31, .up, commandShift)))
    }
}
