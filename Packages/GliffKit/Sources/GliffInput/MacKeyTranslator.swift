/// What one Mac key event means for the remote, before the ledger and capture decide what is
/// sent. Stateless: a modifier's press or release is read from its own device-dependent bit,
/// so left and right stay apart.
public enum KeyAction: Sendable, Equatable {
    case press(UInt32)
    case release(UInt32)
    /// Caps Lock: macOS reports only that its state changed. A press and release toggle the
    /// remote's own lock.
    case toggle(UInt32)
    /// Shift+Esc: give the keyboard back to the Mac. Esc itself is never sent.
    case releaseKeyboard
    /// Nothing to send: an auto-repeat (the remote repeats on its own), Fn, an unknown key.
    case ignore
}

public enum MacKeyTranslator {
    public static func action(for event: MacKeyEvent) -> KeyAction {
        let flags = MacModifierFlags(rawValue: event.flags)
        // Only Caps Lock and the modifiers in `modifiers` are sent from flagsChanged: Fn and the
        // Globe key are not, and aren't unknown keys either.
        if event.kind == .flagsChanged, event.keyCode != capsLock, modifiers[event.keyCode] == nil {
            return .ignore
        }
        guard let code = MacKeyCode.evdev(event.keyCode) else { return .ignore }
        switch event.kind {
        case .down(isRepeat: true):
            return .ignore
        case .down(isRepeat: false):
            if event.keyCode == escape, flags.contains(.shift),
                flags.isDisjoint(with: [.command, .option, .control])
            {
                return .releaseKeyboard
            }
            return .press(code)
        case .up:
            return .release(code)
        case .flagsChanged:
            guard let modifier = modifiers[event.keyCode] else { return .toggle(code) }
            return modifier.isDown(in: flags) ? .press(code) : .release(code)
        }
    }

    static let escape: UInt16 = 0x35
    private static let capsLock: UInt16 = 0x39

    /// The evdev codes of the modifiers (Shift, Control, Option, Command) to hold for `flags`,
    /// in code order: each side whose own device bit is set. A modifier with only its shared
    /// bit (events posted by software can carry no side) is one side: the one in `held`, else
    /// the left.
    public static func modifiersDown(_ flags: UInt, holding held: Set<UInt32> = []) -> [UInt32] {
        let flags = MacModifierFlags(rawValue: flags)
        return pairs.flatMap { pair -> [UInt16] in
            guard flags.contains(pair.shared) else { return [] }
            let sides = [(pair.left, pair.leftFlag), (pair.right, pair.rightFlag)]
            if !flags.isDisjoint(with: [pair.leftFlag, pair.rightFlag]) {
                return sides.filter { flags.contains($0.1) }.map(\.0)
            }
            let heldSides = sides.map(\.0).filter { MacKeyCode.evdev($0).map(held.contains) ?? false }
            return heldSides.isEmpty ? [pair.left] : heldSides
        }.compactMap(MacKeyCode.evdev).sorted()
    }

    /// The evdev codes of the modifiers `flags` says are up. With only a shared bit set, neither
    /// side is known to be up.
    public static func modifiersUp(_ flags: UInt) -> Set<UInt32> {
        let flags = MacModifierFlags(rawValue: flags)
        return Set(modifiers.filter { !$0.value.isDown(in: flags) }.keys.compactMap(MacKeyCode.evdev))
    }

    /// A modifier key: its shared (device-independent) flag, its own device-dependent flag, and
    /// both sides' device-dependent flags.
    private struct Modifier {
        var shared: MacModifierFlags
        var own: MacModifierFlags
        var sides: MacModifierFlags

        /// Down when the shared flag is set and its own flag is, or when no side's flag is set
        /// at all (events posted by software can carry only the shared one).
        func isDown(in flags: MacModifierFlags) -> Bool {
            flags.contains(shared) && (flags.contains(own) || flags.isDisjoint(with: sides))
        }
    }

    /// A modifier's two keys (Mac key codes) and their device bits.
    private struct Pair {
        var shared: MacModifierFlags
        var left: UInt16
        var leftFlag: MacModifierFlags
        var right: UInt16
        var rightFlag: MacModifierFlags
    }

    private static let pairs = [
        Pair(shared: .shift, left: 0x38, leftFlag: .leftShift, right: 0x3C, rightFlag: .rightShift),
        Pair(shared: .control, left: 0x3B, leftFlag: .leftControl, right: 0x3E, rightFlag: .rightControl),
        Pair(shared: .option, left: 0x3A, leftFlag: .leftOption, right: 0x3D, rightFlag: .rightOption),
        Pair(shared: .command, left: 0x37, leftFlag: .leftCommand, right: 0x36, rightFlag: .rightCommand),
    ]

    private static let modifiers: [UInt16: Modifier] = Dictionary(
        uniqueKeysWithValues: pairs.flatMap { pair in
            let sides: MacModifierFlags = [pair.leftFlag, pair.rightFlag]
            return [
                (pair.left, Modifier(shared: pair.shared, own: pair.leftFlag, sides: sides)),
                (pair.right, Modifier(shared: pair.shared, own: pair.rightFlag, sides: sides)),
            ]
        })
}
