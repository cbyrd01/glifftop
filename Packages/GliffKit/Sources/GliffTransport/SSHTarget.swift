import Foundation

/// What the person typed in the connect field, checked before it reaches ssh's argv:
/// `host`, `user@host`, or `ssh://user@host:port`. Surrounding whitespace is trimmed.
public struct SSHTarget: Equatable, Sendable {
    public let value: String

    private static let forbidden = CharacterSet.whitespacesAndNewlines.union(.controlCharacters)
    /// ssh_config's wildcards, which no host has, and the shell characters ssh itself refuses
    /// in a host name (`valid_hostname`): caught here, so the field says why. A user name may
    /// hold some of them, and ssh checks it itself.
    private static let invalid = CharacterSet(charactersIn: "*?'\"`$\\;&<>|(){}")

    public init(_ text: String) throws(SSHTargetError) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw .empty }
        // ssh would read a leading dash as an option (`-oProxyCommand=…` runs a command).
        guard !Self.partStartsWithDash(trimmed) else { throw .startsWithDash }
        guard trimmed.unicodeScalars.allSatisfy({ !Self.forbidden.contains($0) }) else {
            throw .containsWhitespaceOrControl
        }
        guard Self.host(of: trimmed).unicodeScalars.allSatisfy({ !Self.invalid.contains($0) }) else {
            throw .invalidCharacter
        }
        value = trimmed
    }

    /// The whole target, its user (after `ssh://`) or its host (after the last `@`) starting
    /// with `-`: ssh expands user and host into ProxyCommand (%r, %h), past `--`'s protection.
    /// Bytes, not Characters: `-` plus a combining mark is one Character.
    private static func partStartsWithDash(_ target: String) -> Bool {
        let dash = UInt8(ascii: "-")
        return withoutScheme(target).first == dash || host(of: target).utf8.first == dash
    }

    /// The target after a leading `ssh://`, any case. `| 0x20` lowercases letters and leaves
    /// `:` and `/` as they are.
    private static func withoutScheme(_ target: String) -> Substring.UTF8View {
        let bytes = target.utf8[...]
        return bytes.prefix(6).elementsEqual("ssh://".utf8, by: { $0 | 0x20 == $1 })
            ? bytes.dropFirst(6) : bytes
    }

    /// The host, with its port: what follows the last `@`, else the whole target (after
    /// `ssh://`).
    private static func host(of target: String) -> Substring {
        let rest = withoutScheme(target)
        let start = rest.lastIndex(of: UInt8(ascii: "@")).map { rest.index(after: $0) } ?? rest.startIndex
        return Substring(rest[start...])
    }
}

public enum SSHTargetError: Error, Equatable, Sendable {
    case empty
    case startsWithDash
    case containsWhitespaceOrControl
    case invalidCharacter

    /// Shown under the connect field.
    public var message: String {
        switch self {
        case .empty: "Enter a host, like user@host."
        case .startsWithDash: "A host can't start with a dash."
        case .containsWhitespaceOrControl: "A host can't contain spaces or control characters."
        case .invalidCharacter: "A host can't contain * or ?, or characters like $ ; | & ' \" ( )."
        }
    }
}
