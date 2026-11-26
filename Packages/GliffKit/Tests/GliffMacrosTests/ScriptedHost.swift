import GliffTransport
import Synchronization

@testable import GliffMacros

/// A host whose channels answer a run's text with scripted events, its token filled in.
final class ScriptedHost: HostConnection {
    enum Event: Sendable {
        /// The wrapper's start line.
        case start
        case text(String)
        /// A trailer with these words, `exit N` or `timeout`.
        case trailer(String)
        /// The command exits 0.
        case finish
        case fail(TransportError)
    }

    private let events: [Event]
    private let writeHangs: Bool
    private let cancelsOnOpen: Bool
    private let state = Mutex([ScriptedChannel]())
    private let end = AsyncStream<Void>.makeStream()

    /// The events come after the text is written; with none left, the channel stays open.
    /// `writeHangs`: a write never finishes until the channel is closed. `cancelsOnOpen`: the
    /// task that opens a channel is cancelled as it opens, as by a Cancel during the sign-in.
    init(_ events: [Event], writeHangs: Bool = false, cancelsOnOpen: Bool = false) {
        (self.events, self.writeHangs, self.cancelsOnOpen) = (events, writeHangs, cancelsOnOpen)
    }

    var channels: [ScriptedChannel] { state.withLock { $0 } }

    func channel(command: String, logsStderr: Bool) async throws(TransportError) -> any ByteConnection {
        let channel = ScriptedChannel(events: events, logsStderr: logsStderr, writeHangs: writeHangs)
        state.withLock { $0.append(channel) }
        if cancelsOnOpen { withUnsafeCurrentTask { $0?.cancel() } }
        return channel
    }

    func ended() async -> ConnectFailure? {
        for await _ in end.stream {}
        return nil
    }

    func invalidate() async { end.continuation.finish() }
    func close() async { end.continuation.finish() }
}

/// One scripted channel: it records what was written and whether it was closed.
final class ScriptedChannel: ByteConnection {
    let logsStderr: Bool
    let incoming: AsyncThrowingStream<[UInt8], any Error>
    private let continuation: AsyncThrowingStream<[UInt8], any Error>.Continuation
    private let events: [Event]
    private let writeHangs: Bool
    private let closing = AsyncStream<Void>.makeStream()
    private let state = Mutex((writes: [[UInt8]](), closed: false))
    typealias Event = ScriptedHost.Event

    init(events: [Event], logsStderr: Bool, writeHangs: Bool) {
        (incoming, continuation) = AsyncThrowingStream.makeStream()
        (self.events, self.logsStderr, self.writeHangs) = (events, logsStderr, writeHangs)
    }

    var writes: [[UInt8]] { state.withLock { $0.writes } }
    var closed: Bool { state.withLock { $0.closed } }

    func write(_ bytes: [UInt8]) async throws(TransportError) {
        let first = state.withLock { state in
            state.writes.append(bytes)
            return state.writes.count == 1
        }
        if writeHangs {
            for await _ in closing.stream {}
            throw .writeFailed("closed")
        }
        guard first else { return }
        // The text ends with the line `#TOKEN`.
        guard let token = MacroToken(hex: String(decoding: bytes.dropLast().suffix(32), as: UTF8.self)) else {
            return continuation.finish(throwing: TransportError.writeFailed("no token"))
        }
        for event in events {
            switch event {
            case .start: continuation.yield(token.startLine)
            case .text(let text): continuation.yield(Array(text.utf8))
            case .trailer(let words): continuation.yield(token.trailerMarker + Array("\(words)\n".utf8))
            case .finish: continuation.finish()
            case .fail(let error): continuation.finish(throwing: error)
            }
        }
    }

    func close() async {
        state.withLock { $0.closed = true }
        closing.continuation.finish()
        continuation.finish()
    }

    func abandon() async { await close() }
}
