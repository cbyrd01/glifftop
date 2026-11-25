/// A run's token: 32 lowercase hex digits, new for each run, that mark its text's end, its
/// start line and its trailer. It never prints itself, in a description, a debug description
/// or a dump.
public struct MacroToken: Sendable, Equatable {
    let hex: String

    /// `hex` when it is 32 lowercase hex digits.
    init?(hex: String) {
        guard hex.utf8.count == 32, hex.utf8.allSatisfy(Self.digits.utf8.contains) else { return nil }
        self.hex = hex
    }

    private init(words: [UInt64]) {
        hex = words.map { word in
            let digits = String(word, radix: 16)
            return String(repeating: "0", count: 16 - digits.count) + digits
        }.joined()
    }

    private static let digits = "0123456789abcdef"

    /// 128 bits from `SystemRandomNumberGenerator`.
    public static func random() -> MacroToken {
        var generator = SystemRandomNumberGenerator()
        return MacroToken(words: [generator.next(), generator.next()])
    }
}

extension MacroToken: CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    public var description: String { "MacroToken(hidden)" }
    public var debugDescription: String { description }
    public var customMirror: Mirror { Mirror(self, children: []) }
}
