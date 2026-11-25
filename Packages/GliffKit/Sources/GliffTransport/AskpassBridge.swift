#if os(macOS)
    import Foundation
    import GliffAskpass
    import Synchronization
    import os

    /// The app's end of the askpass helper's socket, one per master that may ask: it takes ssh's
    /// questions from the helper, one at a time, asks the person, and gives ssh the answer.
    ///
    /// - A connection is served only when `peer` accepts it and its token matches (compared in
    ///   constant time), each read and write within `ioLimit`.
    /// - A question is classified by `AskpassPrompt`; at most `questionLimit` per sign-in.
    /// - Allow on a host key answers its fingerprint, so ssh accepts exactly the key shown; Deny
    ///   answers "no". A secret is written straight from its own memory.
    /// - Cancel, an unknown question, a refused peer or token, a read error, one question too
    ///   many, or `revoke()`: `outcome` is set and `end` (which ends the master) is awaited before
    ///   the helper is refused, so ssh never sends an empty answer. Once `outcome` is set, every
    ///   connection is refused.
    /// - A connection it closes without an answer is refused (`AskpassReply.Status.refuse`)
    ///   first: a helper whose socket closes with no reply takes the app for gone, and ends its
    ///   ssh (`AskpassHelper`).
    /// - The helper's socket closing while its question is asked cancels that `ask`. For a
    ///   notice that is ssh ending it; for a question, it ends the master too.
    /// - It logs question kinds and counts, never their text or answers.
    public final class AskpassBridge: Sendable {
        public enum Outcome: Equatable, Sendable {
            case denied, cancelled, tooMany, unknownQuestion
        }

        private struct State {
            var outcome: Outcome?
            var questionOpen = false
            var asked = 0
            var revoked = false
            /// Revoked as the master became ready: what comes after needs no ending.
            var ready = false
            var listener: (any DispatchSourceRead)?
            var serving = false
            /// The question being asked, which `revoke()` cancels.
            var question: Task<Step, Never>?
        }

        /// Set once the helper's socket has closed (or sent more than its request).
        private final class Flag: Sendable {
            private let value = Mutex(false)
            var isSet: Bool { value.withLock { $0 } }
            func set() { value.withLock { $0 = true } }
        }

        /// How a question ended.
        private enum Step: Sendable {
            case answered, denied, gone, refused
            /// Refused with nobody signing in any more: no outcome, the master left.
            case closed
        }

        public let path: String
        private let token: [UInt8]
        private let destination: String
        private let names: Set<String>
        private let peer: any AskpassPeerCheck
        private let ask: @Sendable (SignInQuestion) async -> SignInAnswer
        private let end: @Sendable () async -> Void
        private let questionLimit: Int
        private let ioLimit: Duration
        private let state = Mutex(State())
        private let accepted: AsyncStream<Int32>
        private let acceptor: AsyncStream<Int32>.Continuation
        /// Where connections are accepted (internal: a test holds it to keep one in the listen queue).
        let queue = DispatchQueue(label: "me.cbyrd.Glifftop.askpass")
        private static let log = Logger(subsystem: "me.cbyrd.Glifftop", category: "AskpassBridge")

        /// `names` are the destination's names in ssh's questions (`SSHResolvedConfig.names`).
        public init(
            path: String, token: [UInt8], destination: String, names: Set<String>, peer: any AskpassPeerCheck,
            ask: @escaping @Sendable (SignInQuestion) async -> SignInAnswer,
            end: @escaping @Sendable () async -> Void, questionLimit: Int = 10,
            ioLimit: Duration = .seconds(10)
        ) {
            (self.path, self.token, self.destination, self.names, self.peer) = (
                path, token, destination, names, peer
            )
            (self.ask, self.end, self.questionLimit, self.ioLimit) = (ask, end, questionLimit, ioLimit)
            (accepted, acceptor) = AsyncStream.makeStream()
        }

        deinit { revoke() }

        /// A one-time token: 32 random bytes.
        public static func newToken() -> [UInt8] {
            var generator = SystemRandomNumberGenerator()
            return (0..<AskpassWire.tokenLength).map { _ in generator.next() }
        }

        public var questionOpen: Bool { state.withLock(\.questionOpen) }
        public var outcome: Outcome? { state.withLock(\.outcome) }

        /// Listens and serves.
        public func start() throws(TransportError) {
            try listen()
            serve()
        }

        /// Listens on `path`, a socket only this user can open (0600, in a 0700 directory). A
        /// connection waits for `serve()`: start ssh between the two, once its pid is known.
        public func listen() throws(TransportError) {
            guard state.withLock({ $0.listener == nil && !$0.revoked }) else { return }
            unlink(path)
            guard let socket = AskpassSocket.listening(at: path) else {
                unlink(path)
                throw .launchFailed("There's no socket for ssh's sign-in questions.")
            }
            guard fcntl(socket, F_SETFL, fcntl(socket, F_GETFL) | O_NONBLOCK) == 0 else {
                close(socket)
                unlink(path)
                throw .launchFailed("There's no socket for ssh's sign-in questions.")
            }
            let listener = DispatchSource.makeReadSource(fileDescriptor: socket, queue: queue)
            listener.setEventHandler { [weak self] in self?.acceptAll(socket) }
            listener.setCancelHandler { close(socket) }
            state.withLock { $0.listener = listener }
            listener.resume()
        }

        /// Serves the connections, one at a time, from now on.
        public func serve() {
            let first = state.withLock { state in
                defer { state.serving = true }
                return !state.serving
            }
            guard first else { return }
            let accepted = accepted
            Task { [weak self] in
                for await connection in accepted {
                    if let self { await self.serve(connection) } else { Self.refuse(connection) }
                }
            }
        }

        /// The token is dead and the socket closed and removed: no more questions, and an open
        /// one is cancelled. `ready`: the master is ready, so nothing after ends it; otherwise a
        /// question still asked (not a notice) ends it, as ssh would read its closed helper as
        /// an empty answer.
        public func revoke(ready: Bool = false) {
            let (listener, question) = state.withLock { state in
                state.revoked = true
                state.ready = state.ready || ready
                return (state.listener.take(), state.question)
            }
            question?.cancel()
            if let listener {
                // Gone first, so a helper connecting now finds no socket rather than a refusing
                // one (an app gone); then those not yet accepted are refused, not cut off.
                unlink(path)
                let socket = Int32(listener.handle)
                while case let connection = accept(socket, nil, nil), connection >= 0 {
                    configure(connection)
                    Self.refuse(connection)
                }
                listener.cancel()
            }
            acceptor.finish()
        }

        private func acceptAll(_ listener: Int32) {
            while true {
                let connection = accept(listener, nil, nil)
                guard connection >= 0 else { return }
                configure(connection)
                guard case .enqueued = acceptor.yield(connection) else {
                    Self.refuse(connection)
                    continue
                }
            }
        }

        /// Blocking, with SIGPIPE off and `ioLimit` on each read and write.
        private func configure(_ socket: Int32) {
            _ = fcntl(socket, F_SETFL, fcntl(socket, F_GETFL) & ~O_NONBLOCK)
            var on: Int32 = 1
            setsockopt(socket, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
            let (seconds, attoseconds) = ioLimit.components
            var limit = timeval(tv_sec: Int(seconds), tv_usec: Int32(attoseconds / 1_000_000_000_000))
            for option in [SO_RCVTIMEO, SO_SNDTIMEO] {
                setsockopt(socket, SOL_SOCKET, option, &limit, socklen_t(MemoryLayout<timeval>.size))
            }
        }

        private func serve(_ socket: Int32) async {
            let (settled, revoked, ready) = state.withLock { ($0.outcome != nil, $0.revoked, $0.ready) }
            guard !settled, !ready else { return Self.refuse(socket) }
            guard !revoked else { return await fail(.cancelled, socket, "revoked") }
            guard peer.accepts(socket) else { return await fail(.cancelled, socket, "peer refused") }
            guard let request = await blocking({ Self.readRequest(socket) }) else {
                return await fail(.cancelled, socket, "unreadable request")
            }
            guard Self.matches(request.token, token) else {
                return await fail(.cancelled, socket, "wrong token")
            }
            guard
                let question = AskpassPrompt.classify(
                    request.text, kind: request.kind, destination: destination, names: names)
            else { return await fail(.unknownQuestion, socket, "unknown question") }
            let count = state.withLock { state in
                state.asked += 1
                return state.asked
            }
            guard count <= questionLimit else { return await fail(.tooMany, socket, "too many questions") }
            Self.log.info("sign-in question \(count): \(Self.kind(question), privacy: .public)")
            await asking(question, on: socket)
        }

        /// Asks, watching the helper's socket meanwhile. The socket is closed only here, once the
        /// answer is written (or not) and the watch has stopped using it.
        private func asking(_ question: SignInQuestion, on socket: Int32) async {
            let gone = Flag()
            let isNotice = if case .notice = question { true } else { false }
            // Open before the task can answer, so its close always comes after.
            state.withLock { $0.questionOpen = true }
            let task = Task { [self] in
                let answer = await ask(question)
                let (revoked, ready) = state.withLock { state in
                    state.questionOpen = false
                    return (state.revoked, state.ready)
                }
                if gone.isSet { return Step.gone }
                // A notice, or anything once the master is ready, is over, not refused.
                if revoked { return isNotice || ready ? .closed : .refused }
                // ssh fails as soon as it reads "no": the outcome is set first.
                return Self.reply(answer, to: question, on: socket) {
                    state.withLock { $0.outcome = $0.outcome ?? .denied }
                }
            }
            let revoked = state.withLock { state in
                state.question = task
                return state.revoked
            }
            if revoked { task.cancel() }
            let (watchEnded, watchEnd) = AsyncStream.makeStream(of: Void.self)
            let watch = DispatchSource.makeReadSource(fileDescriptor: socket, queue: queue)
            watch.setEventHandler { [weak watch] in
                var byte: UInt8 = 0
                let got = recv(socket, &byte, 1, MSG_PEEK | MSG_DONTWAIT)
                if got < 0, errno == EAGAIN || errno == EINTR { return }
                gone.set()
                task.cancel()
                watch?.cancel()
            }
            watch.setCancelHandler { watchEnd.finish() }
            watch.resume()
            let step = await task.value
            state.withLock { $0.question = nil }
            watch.cancel()
            for await _ in watchEnded {}
            switch step {
            case .answered, .denied:
                close(socket)
                return
            case .closed: break
            case .gone where isNotice: Self.log.info("sign-in notice ended by ssh")
            case .gone, .refused:
                state.withLock { $0.outcome = $0.outcome ?? .cancelled }
                Self.log.info("sign-in question cancelled")
                await end()
            }
            Self.refuse(socket)
        }

        private func fail(_ outcome: Outcome, _ socket: Int32, _ reason: StaticString) async {
            state.withLock { $0.outcome = $0.outcome ?? outcome }
            Self.log.error("askpass connection refused: \(reason, privacy: .public)")
            await end()
            Self.refuse(socket)
        }

        /// Refuses the helper on `socket` and closes it.
        private static func refuse(_ socket: Int32) {
            if let header = try? AskpassReply.header(.refuse, length: 0) {
                _ = header.withUnsafeBytes { AskpassSocket.write(socket, $0) }
            }
            close(socket)
        }

        private static func reply(
            _ answer: consuming SignInAnswer, to question: SignInQuestion, on socket: Int32,
            denying: () -> Void
        ) -> Step {
            switch consume answer {
            case .allow:
                switch question {
                case .hostKey(let key):
                    return send(Array(key.fingerprint.utf8), on: socket) ? .answered : .refused
                case .confirm: return send(Array("yes".utf8), on: socket) ? .answered : .refused
                default: return .refused
                }
            case .deny:
                switch question {
                case .hostKey, .confirm:
                    denying()
                    return send(Array("no".utf8), on: socket) ? .denied : .refused
                default: return .refused
                }
            case .secret(let secret):
                switch question {
                case .passphrase, .password, .fromHost: return send(secret, on: socket) ? .answered : .refused
                default: return .refused
                }
            case .cancel: return .refused
            }
        }

        private static func send(_ bytes: [UInt8], on socket: Int32) -> Bool {
            send(SignInSecret(bytes: bytes), on: socket)
        }

        /// The answer's header, then its bytes from the secret's own memory. A line break or NUL
        /// would end ssh's answer early, so it isn't sent.
        private static func send(_ secret: borrowing SignInSecret, on socket: Int32) -> Bool {
            secret.withBytes { bytes in
                let ends: Set<UInt8> = [0, UInt8(ascii: "\n"), UInt8(ascii: "\r")]
                guard !bytes.contains(where: ends.contains),
                    let header = try? AskpassReply.header(.answer, length: bytes.count)
                else { return false }
                return header.withUnsafeBytes { AskpassSocket.write(socket, $0) }
                    && AskpassSocket.write(socket, bytes)
            }
        }

        private static func readRequest(_ socket: Int32) -> AskpassRequest? {
            var header = [UInt8](repeating: 0, count: AskpassRequest.headerLength)
            guard header.withUnsafeMutableBytes({ AskpassSocket.read(socket, into: $0) }),
                let length = try? AskpassRequest.textLength(header: header)
            else { return nil }
            var text = [UInt8](repeating: 0, count: length)
            guard text.withUnsafeMutableBytes({ AskpassSocket.read(socket, into: $0) }) else { return nil }
            return try? AskpassRequest.decode(header + text)
        }

        /// Equal without stopping at the first difference.
        static func matches(_ given: [UInt8], _ expected: [UInt8]) -> Bool {
            guard given.count == expected.count else { return false }
            return zip(given, expected).reduce(0) { $0 | ($1.0 ^ $1.1) } == 0
        }

        private func blocking<T: Sendable>(_ body: @escaping @Sendable () -> T) async -> T {
            await withCheckedContinuation { result in
                DispatchQueue.global().async { result.resume(returning: body()) }
            }
        }

        private static func kind(_ question: SignInQuestion) -> String {
            switch question {
            case .hostKey: "host key"
            case .confirm: "confirm"
            case .passphrase: "passphrase"
            case .password: "password"
            case .fromHost: "from host"
            case .notice: "notice"
            }
        }
    }
#endif
