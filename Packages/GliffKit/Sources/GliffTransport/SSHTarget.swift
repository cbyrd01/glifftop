import Foundation

/// What the person typed in the connect field, checked before it reaches ssh's argv:
/// `host`, `user@host`, or `ssh://user@host:port`. Surrounding whitespace is trimmed.
public struct SSHTarget: Equatable, Sendable {
    public let value: String

    private static let forbidden = CharacterSet.whitespacesAndNewlines.union(.controlCharacters)

    public init(_ text: String) throws(SSHTargetError) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw .empty }
        // ssh would read a leading dash as an option (`-oProxyCommand=…` runs a command).
        guard !Self.partStartsWithDash(trimmed) else { throw .startsWithDash }
        guard trimmed.unicodeScalars.allSatisfy({ !Self.forbidden.contains($0) }) else {
            throw .containsWhitespaceOrControl
        }
        value = trimmed
    }

    /// The whole target, its user (after `ssh://`) or its host (after the last `@`) starting
    /// with `-`: ssh expands user and host into ProxyCommand (%r, %h), past `--`'s protection.
    /// Bytes, not Characters: `-` plus a combining mark is one Character.
    private static func partStartsWithDash(_ target: String) -> Bool {
        let dash = UInt8(ascii: "-")
        var rest = target.utf8[...]
        // `| 0x20` lowercases letters and leaves `:` and `/` as they are.
        if rest.prefix(6).elementsEqual("ssh://".utf8, by: { $0 | 0x20 == $1 }) { rest = rest.dropFirst(6) }
        let host = rest.lastIndex(of: UInt8(ascii: "@")).map { rest[rest.index(after: $0)...] } ?? rest
        return rest.first == dash || host.first == dash
    }
}

public enum SSHTargetError: Error, Equatable, Sendable {
    case empty
    case startsWithDash
    case containsWhitespaceOrControl

    /// Shown under the connect field.
    public var message: String {
        switch self {
        case .empty: "Enter a host, like user@host."
        case .startsWithDash: "A host can't start with a dash."
        case .containsWhitespaceOrControl: "A host can't contain spaces or control characters."
        }
    }
}
