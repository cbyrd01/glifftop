public import Foundation

/// The askpass helper ssh runs for each question (`SSH_ASKPASS`): it hands ssh's prompt to
/// the app's bridge and gives ssh the answer.
///
/// - The prompt is ssh's one argument; `SSH_ASKPASS_PROMPT=none` makes it a notice, held until
///   the bridge closes the socket or ssh ends the helper. A prompt over `textLimit` bytes is cut
///   at a character's end.
/// - An answer goes to `output` with a newline, written from a buffer that is then cleared, and
///   the helper exits 0. A refusal, a closed socket, a missing variable, any malformed reply, or
///   an answer with a line break or NUL (ssh would send only what comes before it) writes
///   nothing and exits 1: ssh then sends nothing to the host. SIGPIPE is ignored, so a closed
///   `output` is a failure too.
/// - It never logs.
public enum AskpassHelper {
    public static func run(
        arguments: [String] = CommandLine.arguments,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        output: Int32 = STDOUT_FILENO
    ) -> Int32 {
        guard let path = environment[AskpassWire.socketVariable],
            let token = environment[AskpassWire.tokenVariable].flatMap(bytes(hex:)),
            token.count == AskpassWire.tokenLength
        else { return 1 }
        signal(SIGPIPE, SIG_IGN)
        let kind: AskpassRequest.Kind = environment["SSH_ASKPASS_PROMPT"] == "none" ? .notice : .ask
        let prompt = clipped(arguments.dropFirst().first ?? "", to: AskpassWire.textLimit)
        guard let socket = AskpassSocket.connect(to: path) else { return 1 }
        defer { close(socket) }
        let request = AskpassRequest(token: token, kind: kind, text: prompt).encoded()
        guard request.withUnsafeBytes({ AskpassSocket.write(socket, $0) }) else { return 1 }
        if kind == .notice {
            var byte: UInt8 = 0
            while true {
                let got = read(socket, &byte, 1)
                if got > 0 || (got < 0 && errno == EINTR) { continue }
                return 1
            }
        }
        return answer(from: socket, to: output) ? 0 : 1
    }

    /// Reads the reply and writes its answer and a newline to `output`.
    private static func answer(from socket: Int32, to output: Int32) -> Bool {
        var header = [UInt8](repeating: 0, count: AskpassReply.headerLength)
        guard header.withUnsafeMutableBytes({ AskpassSocket.read(socket, into: $0) }),
            let (status, length) = try? AskpassReply.decodeHeader(header), status == .answer
        else { return false }
        let buffer = UnsafeMutableRawBufferPointer.allocate(byteCount: length + 1, alignment: 1)
        defer {
            if let base = buffer.baseAddress { memset_s(base, buffer.count, 0, buffer.count) }
            buffer.deallocate()
        }
        guard AskpassSocket.read(socket, into: UnsafeMutableRawBufferPointer(rebasing: buffer[..<length]))
        else { return false }
        let ends: Set<UInt8> = [0, UInt8(ascii: "\n"), UInt8(ascii: "\r")]
        guard !buffer[..<length].contains(where: ends.contains) else { return false }
        buffer[length] = UInt8(ascii: "\n")
        return AskpassSocket.write(output, UnsafeRawBufferPointer(buffer))
    }

    /// `text` cut to at most `limit` UTF-8 bytes, at a character's end.
    static func clipped(_ text: String, to limit: Int) -> String {
        guard text.utf8.count > limit else { return text }
        var count = 0
        var end = text.startIndex
        for index in text.indices {
            let next = text.index(after: index)
            count += text[index..<next].utf8.count
            guard count <= limit else { break }
            end = next
        }
        return String(text[..<end])
    }

    private static func bytes(hex: String) -> [UInt8]? {
        let digits = Array(hex.utf8)
        guard digits.count.isMultiple(of: 2) else { return nil }
        var bytes: [UInt8] = []
        for index in stride(from: 0, to: digits.count, by: 2) {
            guard let byte = UInt8(String(decoding: digits[index...index + 1], as: UTF8.self), radix: 16)
            else { return nil }
            bytes.append(byte)
        }
        return bytes
    }
}
