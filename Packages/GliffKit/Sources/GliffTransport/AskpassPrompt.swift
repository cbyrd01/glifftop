import Foundation
public import GliffAskpass

/// Tells ssh's questions apart by their text, each anchored at its first byte. Only ssh's own
/// templates count: a text that starts with "(" is ssh's "(USER@HOST) " before the host's own
/// words, which are never matched against any template. stderr is never read for this.
public enum AskpassPrompt {
    /// The question `text` asks, or nil for a text ssh doesn't write (the bridge cancels it).
    /// `destination` is the host as typed; `names` are the names ssh writes for it (the probe's
    /// HostName and HostKeyAlias, also as `[name]:port`), which a question shows as
    /// `destination`. Any other name is a jump host's, shown as ssh wrote it.
    public static func classify(
        _ text: String, kind: AskpassRequest.Kind, destination: String, names: Set<String>
    ) -> SignInQuestion? {
        if kind == .notice { return .notice(host: destination, text: text) }
        let host = { (name: Substring) in shown(name, destination: destination, names: names) }
        if text.hasPrefix("(") { return fromHost(text, host: host) }
        if text.hasPrefix(hostKeyStart) { return hostKey(text, host: host).map(SignInQuestion.hostKey) }
        if text == continueQuestion || (text.hasPrefix("Warning: the ") && text.hasSuffix("(yes/no)? ")) {
            return .confirm(host: destination, text: text)
        }
        if text.hasPrefix("Enter passphrase for key '") || text.hasPrefix("Enter PIN for ") {
            return .passphrase(host: destination, text: text)
        }
        return password(text, host: host)
    }

    /// `destination` for a name ssh writes for it, else the name as written.
    private static func shown(_ name: Substring, destination: String, names: Set<String>) -> String {
        var bare = name
        if bare.hasPrefix("["), let close = bare.lastIndex(of: "]") {
            bare = bare[bare.index(after: bare.startIndex)..<close]
        }
        let lowered = bare.lowercased()
        return names.contains { $0.lowercased() == lowered } ? destination : String(name)
    }

    private static let hostKeyStart = "The authenticity of host '"
    private static let continueQuestion = "Are you sure you want to continue connecting (yes/no)? "
    private static let passwordShapes = [
        ("", "'s password: "), ("Enter ", "'s old password: "), ("Enter ", "'s new password: "),
        ("Retype ", "'s new password: "),
    ]

    /// A fingerprint as ssh prints one: SHA256, or MD5 under `FingerprintHash md5`.
    static func isFingerprint(_ text: some StringProtocol) -> Bool {
        text.hasPrefix("SHA256:") || text.hasPrefix("MD5:")
    }

    /// "(USER@HOST) " and the host's words after it. ssh's ") " is found in the bytes: matched
    /// by Characters, a combining mark at the host's first byte would hide it.
    private static func fromHost(_ text: String, host: (Substring) -> String) -> SignInQuestion? {
        let bytes = Array(text.utf8)
        guard let close = bytes.firstRange(of: Array(") ".utf8)) else { return nil }
        let inside = Substring(decoding: bytes[1..<close.lowerBound], as: UTF8.self)
        let name = inside.lastIndex(of: "@").map { inside[inside.index(after: $0)...] } ?? inside
        guard !name.isEmpty else { return nil }
        return .fromHost(
            host: host(name), prefix: String(decoding: bytes[..<close.upperBound], as: UTF8.self),
            text: String(decoding: bytes[close.upperBound...], as: UTF8.self))
    }

    /// ssh's unknown-key question: the host up to " (", the "<TYPE> key fingerprint is: " line,
    /// and every other line but the first and the question as details.
    private static func hostKey(_ text: String, host shown: (Substring) -> String) -> HostKeyQuestion? {
        guard text.trimmingCharacters(in: .whitespacesAndNewlines).hasSuffix("(yes/no/[fingerprint])?") else {
            return nil
        }
        var lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        guard lines.count >= 3 else { return nil }
        let named = lines.removeFirst().dropFirst(hostKeyStart.count)
        lines.removeLast()
        guard let host = named.split(separator: " (").first?.split(separator: "'").first, !host.isEmpty,
            let index = lines.firstIndex(where: { $0.contains(" key fingerprint is: ") })
        else { return nil }
        let parts = lines.remove(at: index).split(separator: " key fingerprint is: ", maxSplits: 1)
        guard parts.count == 2, !parts[0].contains(" "),
            isFingerprint(parts[1])
        else { return nil }
        return HostKeyQuestion(
            host: shown(host), keyType: String(parts[0]), fingerprint: String(parts[1]),
            details: lines.filter { !$0.isEmpty })
    }

    /// ssh's password questions: `USER@HOST` on one line in one of its templates; the user may
    /// have spaces, the host has none.
    private static func password(_ text: String, host shown: (Substring) -> String) -> SignInQuestion? {
        for (start, end) in passwordShapes where text.hasPrefix(start) && text.hasSuffix(end) {
            let account = text.dropFirst(start.count).dropLast(end.count)
            guard !account.contains(where: \.isNewline), let at = account.lastIndex(of: "@"),
                at != account.startIndex
            else { continue }
            let host = account[account.index(after: at)...]
            guard !host.isEmpty, !host.contains(where: \.isWhitespace) else { continue }
            return .password(host: shown(host), account: String(account), text: text)
        }
        return nil
    }
}
