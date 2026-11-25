/// A question a sign-in asks the person, whichever ssh asks it. Each names the host it is for:
/// the destination as typed, or a jump host's name as ssh wrote it.
public enum SignInQuestion: Equatable, Sendable {
    /// A host key this Mac doesn't know.
    case hostKey(HostKeyQuestion)
    /// Another yes/no question, in ssh's own words.
    case confirm(host: String, text: String)
    /// A key file's passphrase or a security key's PIN, in ssh's words.
    case passphrase(host: String, text: String)
    /// A password for `account` (`USER@HOST` as ssh wrote it), also ssh's expired-password
    /// questions.
    case password(host: String, account: String, text: String)
    /// The host's own question (keyboard-interactive): `prefix` is ssh's, `text` the host's,
    /// which is untrusted.
    case fromHost(host: String, prefix: String, text: String)
    /// Something to show until ssh ends it, with nothing to answer (a security key's touch).
    case notice(host: String, text: String)

    public var host: String {
        switch self {
        case .hostKey(let question): question.host
        case .confirm(let host, _), .passphrase(let host, _), .password(let host, _, _),
            .fromHost(let host, _, _), .notice(let host, _):
            host
        }
    }
}

/// An unknown host key: its type, its SHA256 fingerprint, and ssh's other lines about it (the
/// other names it knows the key by).
public struct HostKeyQuestion: Equatable, Sendable {
    public var host: String
    public var keyType: String
    public var fingerprint: String
    public var details: [String]

    public init(host: String, keyType: String, fingerprint: String, details: [String]) {
        (self.host, self.keyType, self.fingerprint, self.details) = (host, keyType, fingerprint, details)
    }
}

/// The person's answer. Allow and Deny answer a host key; a secret answers the rest.
public enum SignInAnswer: ~Copyable, Sendable {
    case allow
    case deny
    case secret(SignInSecret)
    case cancel
}

/// Who answers a sign-in's questions: the app's window. A cancelled asking task means
/// `.cancel`.
public protocol SignInAsker: Sendable {
    func ask(_ question: SignInQuestion) async -> SignInAnswer
}
