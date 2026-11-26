#if os(macOS)
    import Foundation
    import GliffProtocol
    import GliffVideo
    import Synchronization

    @testable import GliffSession
    @testable import GliffTransport

    /// `tools/fake-server serve`, found through `GLIFFTOP_FAKE_SERVER` (scripts/test.sh sets it).
    enum FakeServer {
        static var path: String? { ProcessInfo.processInfo.environment["GLIFFTOP_FAKE_SERVER"] }
        static var isAvailable: Bool { path != nil }

        static func transport(_ args: [String]) -> ProcessTransport? {
            path.map { ProcessTransport(executable: URL(filePath: $0), arguments: ["serve"] + args) }
        }
    }

    /// A fake-server transport that keeps the connection, to read the fake's verdict.
    final class ObservedTransport: Transport {
        private let inner: ProcessTransport
        private let opened = Mutex<ProcessConnection?>(nil)

        init?(_ args: [String]) {
            guard let inner = FakeServer.transport(args) else { return nil }
            self.inner = inner
        }

        func connect() async throws(TransportError) -> any ByteConnection {
            let connection = try await inner.connect()
            opened.withLock { $0 = connection as? ProcessConnection }
            return connection
        }

        var connection: ProcessConnection? { opened.withLock { $0 } }

        /// nil if the fake server exited 0 (the client behaved), else what it said.
        var serverFailure: String? {
            guard let connection else { return "never connected" }
            guard let status = connection.exitStatus else { return "still running" }
            if status == 0 { return nil }
            return "exit \(status): " + String(decoding: connection.stderrTail, as: UTF8.self)
        }
    }

    /// Answers every frame with `.noPicture`, and tells the test which frames it saw.
    final class SpyDecoder: FrameDecoder {
        private let configured = Mutex<[StreamConfig]>([])
        private let updated = Mutex<[StreamConfig]>([])
        let decodedFrames: AsyncStream<UInt64>
        private let continuation: AsyncStream<UInt64>.Continuation

        init() {
            (decodedFrames, continuation) = AsyncStream.makeStream()
        }

        var configs: [StreamConfig] { configured.withLock { $0 } }
        var updates: [StreamConfig] { updated.withLock { $0 } }

        func configure(_ config: StreamConfig) async throws {
            configured.withLock { $0.append(config) }
        }

        func update(_ config: StreamConfig) async {
            updated.withLock { $0.append(config) }
        }

        func decode(_ frame: VideoFrameHeader, main: ArraySlice<UInt8>, aux: ArraySlice<UInt8>) async
            -> DecodeOutcome
        {
            continuation.yield(frame.frameID)
            return .noPicture
        }

        /// Returns once frame `id` has been decoded.
        func waitFor(_ id: UInt64) async {
            for await decoded in decodedFrames where decoded == id { return }
        }
    }

    /// Holds `configure` until the test calls `open()`.
    final class GatedDecoder: FrameDecoder {
        private let started: AsyncStream<Void>
        private let startedContinuation: AsyncStream<Void>.Continuation
        private let gate: AsyncStream<Void>
        private let gateContinuation: AsyncStream<Void>.Continuation

        init() {
            (started, startedContinuation) = AsyncStream.makeStream()
            (gate, gateContinuation) = AsyncStream.makeStream()
        }

        func configure(_ config: StreamConfig) async throws {
            startedContinuation.yield()
            for await _ in gate { return }
        }

        func decode(_ frame: VideoFrameHeader, main: ArraySlice<UInt8>, aux: ArraySlice<UInt8>) async
            -> DecodeOutcome
        { .noPicture }

        /// Returns once `configure` has been called.
        func configuring() async {
            for await _ in started { return }
        }

        func open() { gateContinuation.finish() }
    }

    /// A feature that claims variant 99 and records what it is given.
    final class RecordingFeature: SessionFeature {
        enum Event: Equatable {
            case activated
            case received(variant: Int64, body: [UInt8], payload: [UInt8])
        }

        let name = "test-feature"
        let serverVariants: Set<Int64> = [99]
        private let log = Mutex<[Event]>([])

        var events: [Event] { log.withLock { $0 } }

        func activate(_ context: FeatureContext) async {
            log.withLock { $0.append(.activated) }
        }

        func receive(variant: Int64, body: [UInt8], payload: [UInt8]) async {
            log.withLock { $0.append(.received(variant: variant, body: body, payload: payload)) }
        }
    }

    /// Keeps every protocol event, in order.
    final class RecordingObserver: ProtocolObserver {
        private let kept = Mutex<[ProtocolEvent]>([])
        var events: [ProtocolEvent] { kept.withLock { $0 } }
        func observed(_ event: ProtocolEvent) { kept.withLock { $0.append(event) } }

        /// How many `type` messages went `direction` so far.
        func count(_ direction: ProtocolEvent.Direction, _ type: String) -> Int {
            kept.withLock { $0.count { $0.direction == direction && $0.type == type } }
        }
    }

    /// Polls `condition` every 10 ms until it holds; false if it doesn't `within` that long.
    func eventually(within limit: Duration = .seconds(5), _ condition: () -> Bool) async -> Bool {
        for _ in 0..<Int(limit / .milliseconds(10)) where !condition() {
            try? await Task.sleep(for: .milliseconds(10))
        }
        return condition()
    }
#endif
