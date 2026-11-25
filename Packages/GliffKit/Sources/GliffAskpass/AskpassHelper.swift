public import Foundation

/// The askpass helper ssh runs for each question (`SSH_ASKPASS`): it hands ssh's prompt to
/// the app's bridge and gives ssh the answer.
///
/// - The prompt is ssh's one argument; `SSH_ASKPASS_PROMPT=none` makes it a notice, held until
///   the bridge closes the socket or ssh ends the helper. A prompt over `textLimit` bytes is cut
///   at a character's end.
/// - An answer goes to `output` with a newline, written from a buffer that is then cleared, and
///   the helper exits 0. A refusal, a missing variable, any malformed reply, or an answer with a
///   line break or NUL (ssh would send only what comes before it) writes nothing and exits 1.
///   SIGPIPE is ignored, so a closed `output` is a failure too.
/// - ssh reads a failed helper as an empty answer, and sends an empty password. The bridge ends
///   ssh itself before failing a question, and refuses (`.refuse`) when it leaves ssh running;
///   it removes its socket when it stops. So a question whose socket closes before a whole
///   reply, or whose socket is still there but refuses the connection, has lost the app (a
///   crash, Force Quit): the helper calls `endSSH` (`endParentSSH`) before it exits 1. A notice
///   never does.
/// - It never logs.
public enum AskpassHelper {
    public static func run(
        arguments: [String] = CommandLine.arguments,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        output: Int32 = STDOUT_FILENO, endSSH: () -> Void = endParentSSH
    ) -> Int32 {
        guard let path = environment[AskpassWire.socketVariable],
            let token = environment[AskpassWire.tokenVariable].flatMap(bytes(hex:)),
            token.count == AskpassWire.tokenLength
        else { return 1 }
        signal(SIGPIPE, SIG_IGN)
        let kind: AskpassRequest.Kind = environment["SSH_ASKPASS_PROMPT"] == "none" ? .notice : .ask
        let prompt = clipped(arguments.dropFirst().first ?? "", to: AskpassWire.textLimit)
        guard let socket = AskpassSocket.connect(to: path) else {
            // A socket removed was the bridge stopping; one that refuses was left by an app gone.
            if errno == ECONNREFUSED, kind == .ask { endSSH() }
            return 1
        }
        defer { close(socket) }
        let request = AskpassRequest(token: token, kind: kind, text: prompt).encoded()
        // A refusal may come before the bridge reads the request: the reply is read either way.
        _ = request.withUnsafeBytes { AskpassSocket.write(socket, $0) }
        if kind == .notice {
            var byte: UInt8 = 0
            while true {
                let got = read(socket, &byte, 1)
                if got > 0 || (got < 0 && errno == EINTR) { continue }
                return 1
            }
        }
        switch answer(from: socket, to: output) {
        case .answered: return 0
        case .failed: return 1
        case .noReply:
            endSSH()
            return 1
        }
    }

    /// Ends the ssh that ran the helper (SIGTERM), so it never sends an empty answer: only an
    /// ssh at `/usr/bin/ssh`, never launchd (an ssh already gone).
    public static func endParentSSH() {
        #if os(macOS)
            let parent = getppid()
            guard parent > 1 else { return }
            var path = [UInt8](repeating: 0, count: Int(MAXPATHLEN))
            guard path.withUnsafeMutableBytes({ proc_pidpath(parent, $0.baseAddress, UInt32($0.count)) }) > 0,
                String(validating: path.prefix { $0 != 0 }, as: UTF8.self) == "/usr/bin/ssh"
            else { return }
            kill(parent, SIGTERM)
        #endif
    }

    private enum Reply { case answered, failed, noReply }

    /// Reads the reply and writes its answer and a newline to `output`. The bridge always
    /// writes a whole reply, so one cut short is `noReply`.
    private static func answer(from socket: Int32, to output: Int32) -> Reply {
        var header = [UInt8](repeating: 0, count: AskpassReply.headerLength)
        guard header.withUnsafeMutableBytes({ AskpassSocket.read(socket, into: $0) }) else { return .noReply }
        guard let (status, length) = try? AskpassReply.decodeHeader(header), status == .answer else {
            return .failed
        }
        let buffer = UnsafeMutableRawBufferPointer.allocate(byteCount: length + 1, alignment: 1)
        defer {
            if let base = buffer.baseAddress { memset_s(base, buffer.count, 0, buffer.count) }
            buffer.deallocate()
        }
        guard AskpassSocket.read(socket, into: UnsafeMutableRawBufferPointer(rebasing: buffer[..<length]))
        else { return .noReply }
        let ends: Set<UInt8> = [0, UInt8(ascii: "\n"), UInt8(ascii: "\r")]
        guard !buffer[..<length].contains(where: ends.contains) else { return .failed }
        buffer[length] = UInt8(ascii: "\n")
        return AskpassSocket.write(output, UnsafeRawBufferPointer(buffer)) ? .answered : .failed
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
