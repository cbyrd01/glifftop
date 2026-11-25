/// What a sheet may show of a question's text.
extension SignInQuestion {
    /// The most of the host's own text shown, in UTF-8.
    static let hostTextLimit = 8 * 1024

    /// The host's text (`.fromHost`) as a sheet may show it: line breaks kept, but no other
    /// control characters (escape codes), no format characters (bidirectional controls) and
    /// no other line or paragraph separators, cut at `hostTextLimit` bytes with "…".
    public static func shownHostText(_ text: String) -> String {
        var shown = String.UnicodeScalarView()
        var bytes = 0
        for scalar in text.unicodeScalars
        where scalar == "\n" || !SSHErrorClassifier.hidden.contains(scalar.properties.generalCategory) {
            bytes += UTF8.width(scalar)
            guard bytes <= hostTextLimit else { return String(shown) + "…" }
            shown.append(scalar)
        }
        return String(shown)
    }

    /// The key file a passphrase question names (ssh's "Enter passphrase for key 'PATH': "),
    /// cleaned as remote text is; nil for a PIN or any other question.
    public var keyPath: String? {
        guard case .passphrase(_, let text) = self, text.hasPrefix(Self.keyQuestion) else { return nil }
        let rest = text.dropFirst(Self.keyQuestion.count)
        guard let close = rest.lastIndex(of: "'") else { return nil }
        return SSHErrorClassifier.displayable(rest[..<close])
    }

    /// A password question's user, from ssh's USER@HOST split at the last "@" (a host name has
    /// none), cleaned as remote text is; nil for any other question, or an account without one.
    public var user: String? {
        guard case .password(_, let account, _) = self, let at = account.lastIndex(of: "@") else {
            return nil
        }
        let user = SSHErrorClassifier.displayable(account[..<at])
        return user.isEmpty ? nil : user
    }

    /// The host as a heading names it: the host part of what was typed (no user or ssh://,
    /// the port kept), never ssh's resolved HostName; or a jump host's name as ssh wrote it.
    public var hostShown: String { SSHErrorClassifier.displayable(SSHTarget.host(of: host)) }

    private static let keyQuestion = "Enter passphrase for key '"
}
