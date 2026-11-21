/// A Mac key event as plain values, so the rules are testable without AppKit: what the app's
/// adapter reads from an `NSEvent`. `keyCode` is already positional (`MacKeyCode.positional`).
public struct MacKeyEvent: Sendable, Equatable {
    public enum Kind: Sendable, Equatable {
        case down(isRepeat: Bool)
        case up
        /// A modifier or Caps Lock changed; `keyCode` says which key.
        case flagsChanged
    }

    public var keyCode: UInt16
    public var kind: Kind
    /// `NSEvent.modifierFlags.rawValue`, device-dependent bits included (`MacModifierFlags`).
    public var flags: UInt

    public init(keyCode: UInt16, kind: Kind, flags: UInt) {
        self.keyCode = keyCode
        self.kind = kind
        self.flags = flags
    }
}

/// The bits of `NSEvent.modifierFlags`: AppKit's device-independent ones, and the
/// device-dependent ones (IOKit's `NX_DEVICE…KEYMASK`) that tell left from right.
public struct MacModifierFlags: OptionSet, Sendable {
    public let rawValue: UInt
    public init(rawValue: UInt) { self.rawValue = rawValue }

    public static let capsLock = Self(rawValue: 1 << 16)
    public static let shift = Self(rawValue: 1 << 17)
    public static let control = Self(rawValue: 1 << 18)
    public static let option = Self(rawValue: 1 << 19)
    public static let command = Self(rawValue: 1 << 20)
    public static let function = Self(rawValue: 1 << 23)

    public static let leftControl = Self(rawValue: 0x1)
    public static let leftShift = Self(rawValue: 0x2)
    public static let rightShift = Self(rawValue: 0x4)
    public static let leftCommand = Self(rawValue: 0x8)
    public static let rightCommand = Self(rawValue: 0x10)
    public static let leftOption = Self(rawValue: 0x20)
    public static let rightOption = Self(rawValue: 0x40)
    public static let rightControl = Self(rawValue: 0x2000)
}
