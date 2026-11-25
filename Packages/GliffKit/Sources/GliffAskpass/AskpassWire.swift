/// The wire between the askpass helper and the app's bridge: one request, then one reply, on
/// a Unix socket. Every length is checked against its limit before anything is read.
///
/// - Request: version, kind, the 32-byte token, the text's length (UInt32, big-endian), the
///   text in UTF-8 (at most `textLimit` bytes).
/// - Reply: version, status, the answer's length (UInt16, big-endian), the answer's bytes (at
///   most `answerLimit`; none for a refusal). The answer may be a secret, so it is never built
///   as an array here: the bridge writes it from its own buffer after `AskpassReply.header`.
public enum AskpassWire {
    public static let version: UInt8 = 1
    public static let tokenLength = 32
    public static let textLimit = 8 * 1024
    public static let answerLimit = 1024
    /// The helper's environment: the bridge's socket, and the token in hex.
    public static let socketVariable = "GLIFFTOP_ASKPASS_SOCKET"
    public static let tokenVariable = "GLIFFTOP_ASKPASS_TOKEN"

    /// `token` as `tokenVariable` holds it: lowercase hex.
    public static func tokenText(_ token: [UInt8]) -> String {
        let digits = Array("0123456789abcdef".utf8)
        return String(
            decoding: token.flatMap { [digits[Int($0 >> 4)], digits[Int($0 & 0xF)]] }, as: UTF8.self)
    }

    public enum Error: Swift.Error, Equatable, Sendable {
        case version, short, tooLong, malformed
    }
}

/// What the helper asks: ssh's prompt, and whether ssh wants an answer.
public struct AskpassRequest: Equatable, Sendable {
    public enum Kind: UInt8, Sendable {
        /// ssh waits for an answer.
        case ask = 0
        /// `SSH_ASKPASS_PROMPT=none`: shown until ssh ends the helper.
        case notice = 1
    }

    public static let headerLength = lengthOffset + 4
    private static let tokenRange = 2..<(2 + AskpassWire.tokenLength)
    private static let lengthOffset = tokenRange.upperBound

    public var token: [UInt8]
    public var kind: Kind
    public var text: String

    public init(token: [UInt8], kind: Kind, text: String) {
        (self.token, self.kind, self.text) = (token, kind, text)
    }

    public func encoded() -> [UInt8] {
        let text = Array(text.utf8)
        let length = UInt32(text.count)
        return [AskpassWire.version, kind.rawValue] + token
            + [24, 16, 8, 0].map { UInt8(truncatingIfNeeded: length >> $0) } + text
    }

    /// The text's length from a request's first `headerLength` bytes.
    public static func textLength(header: [UInt8]) throws(AskpassWire.Error) -> Int {
        guard header.count >= headerLength else { throw .short }
        guard header[0] == AskpassWire.version else { throw .version }
        let length = header[lengthOffset..<headerLength].reduce(0) { $0 << 8 | Int($1) }
        guard length <= AskpassWire.textLimit else { throw .tooLong }
        return length
    }

    public static func decode(_ bytes: [UInt8]) throws(AskpassWire.Error) -> AskpassRequest {
        let length = try textLength(header: bytes)
        guard let kind = Kind(rawValue: bytes[1]) else { throw .malformed }
        guard bytes.count >= headerLength + length else { throw .short }
        guard bytes.count == headerLength + length,
            let text = String(validating: bytes[headerLength...], as: UTF8.self)
        else { throw .malformed }
        return AskpassRequest(token: Array(bytes[tokenRange]), kind: kind, text: text)
    }
}

/// The bridge's reply: an answer for ssh, or a refusal (the helper then exits 1).
public enum AskpassReply {
    public enum Status: UInt8, Sendable {
        case answer = 0
        case refuse = 1
    }

    public static let headerLength = 4

    /// The header before `length` bytes of answer; a refusal has none.
    public static func header(_ status: Status, length: Int) throws(AskpassWire.Error) -> [UInt8] {
        guard (0...AskpassWire.answerLimit).contains(length) else { throw .tooLong }
        guard status == .answer || length == 0 else { throw .malformed }
        return [AskpassWire.version, status.rawValue, UInt8(length >> 8), UInt8(length & 0xFF)]
    }

    public static func decodeHeader(_ bytes: [UInt8]) throws(AskpassWire.Error) -> (
        status: Status, length: Int
    ) {
        guard bytes.count == headerLength else { throw .short }
        guard bytes[0] == AskpassWire.version else { throw .version }
        guard let status = Status(rawValue: bytes[1]) else { throw .malformed }
        let length = Int(bytes[2]) << 8 | Int(bytes[3])
        guard length <= AskpassWire.answerLimit else { throw .tooLong }
        guard status == .answer || length == 0 else { throw .malformed }
        return (status, length)
    }
}
