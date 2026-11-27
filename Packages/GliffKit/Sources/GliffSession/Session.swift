public import Foundation
public import GliffClipboard
import GliffInput
import GliffProtocol
public import GliffTransport
public import GliffVideo
import Synchronization
import os

/// One Gliff session (one tab): connects, runs the handshake and stream through
/// `SessionCore`, feeds the decoder, and reports through `status`. Upstream's client loop
/// (`net.rs`) as an actor: a reader, one writer task, and a 500 ms tick.
public actor Session {
    /// Every status, ending with `.ended`, after which the stream finishes.
    public nonisolated let status: AsyncStream<SessionStatus>
    private let continuation: AsyncStream<SessionStatus>.Continuation

    private let transport: any Transport
    private let decoder: any FrameDecoder
    private let cursor: CursorSlot
    private let pointer: RemotePointerSlot
    let observer: (any ProtocolObserver)?
    /// Whether an invalid cursor shape has been logged: a server sending them keeps doing so.
    private var loggedInvalidCursor = false
    private let features: [String: any SessionFeature]
    var core: SessionCore
    private var parser = FrameParser()
    private var connection: (any ByteConnection)?
    /// A probe went unanswered: the connection is abandoned, not closed.
    var linkLost = false
    /// Reconnect Now: a link interrupted when the session ends is abandoned too.
    private var abandonsQuietLink = false
    /// Connects, then reads; cancelled by a Disconnect while it is still connecting.
    private var reader: Task<Void, Never>?
    var writer: SessionWriter?
    private var ticks: Task<Void, Never>?
    let inputs: InputQueue
    /// Held while `run()` runs.
    private let awake: Awake
    /// The app's barrier between sessions' input, if it keeps one (`Session+Barrier.swift`).
    nonisolated let barrier: InputBarrier?
    /// This session, to the barrier.
    nonisolated let inputSender = InputBarrier.Sender()
    /// The Pings sent and Pongs heard, for the barrier's answers.
    var fences = FenceLedger()
    private var inputGate = InputGate()
    /// Sends what `inputs` holds each time it wakes, from the handshake on.
    private var inputDrain: Task<Void, Never>?
    private var started = false
    /// Closing down, once the core has finished; `run()` returns after it.
    private var shutdown: Task<Void, Never>?
    private var recorder: StreamRecorder?
    /// The failure reasons logged since the last picture: a run of failures logs each reason
    /// once, so the one that keeps a stream stuck (a failing keyframe) shows after the first,
    /// and a stuck stream's keyframe cycles don't log again. A new coded stream starts a new
    /// run. Reasons carry server values, so a run logs at most `maxLoggedDecodeFailures`.
    private var loggedDecodeFailures: Set<String> = []
    /// Whether the link has gone quiet while streaming (only the client's Pings arm it), and
    /// the wake probe (`Session+Probe.swift`).
    var liveness = Liveness()
    private static let maxLoggedDecodeFailures = 16
    /// The StreamConfig in force, as received, for a recording started mid-stream.
    private var config: Frame?
    /// The window's latest size and scale, from any thread (latest wins).
    nonisolated let viewTarget = Mutex<ViewTarget?>(nil)
    /// The window's live resize's starts (true) and ends, from any thread, in order, until taken.
    nonisolated let liveResizeEdges = Mutex<[Bool]>([])
    /// Numbers each `probe()` and `withdrawProbe()` as it's called, for `Liveness` to order.
    nonisolated let probeCalls = Mutex<UInt64>(0)
    /// Sends a Resize once the latest target has settled.
    var resizeWake: Task<Void, Never>?
    /// The session's clipboard, when the app shares it (`Session+Clipboard.swift`).
    public nonisolated let clipboard: ClipboardBridge?
    /// Where the bridge's messages go: straight to the writer, so an offer is queued there
    /// before `ClipboardBridge.offer` returns.
    let clipboardWire = ClipboardWire()
    /// Turns the bridge's events into statuses.
    var clipboardEvents: Task<Void, Never>?
    /// A clipboard command is being carried out: the input queued after it waits.
    var carryingOut = false

    static let tickInterval = Duration.milliseconds(500)
    /// How long closing waits for queued frames (Bye) to be written.
    static let drainLimit = Duration.seconds(1)
    static let log = Logger(subsystem: "io.github.cbyrd01.Glifftop", category: "GliffSession")

    public init(
        transport: any Transport, configuration: SessionConfiguration, decoder: any FrameDecoder,
        features: [any SessionFeature] = [], cursor: CursorSlot = CursorSlot(),
        pointer: RemotePointerSlot = RemotePointerSlot(), clipboard: ClipboardSetup? = nil,
        observer: (any ProtocolObserver)? = nil, barrier: InputBarrier? = nil, awake: Awake = .process
    ) {
        precondition(Set(features.map(\.name)).count == features.count, "two features have the same name")
        let claimed = features.flatMap(\.serverVariants)
        precondition(Set(claimed).count == claimed.count, "two features claim the same server variant")
        self.transport = transport
        self.decoder = decoder
        self.cursor = cursor
        (self.pointer, self.observer) = (pointer, observer)
        self.features = Dictionary(uniqueKeysWithValues: features.map { ($0.name, $0) })
        core = SessionCore(configuration: configuration, features: self.features.mapValues(\.serverVariants))
        (status, continuation) = AsyncStream.makeStream(bufferingPolicy: .bufferingNewest(256))
        self.clipboard = Self.makeClipboard(clipboard, wire: clipboardWire)
        self.barrier = barrier
        self.awake = awake
        inputs = InputQueue(clock: barrier?.clock ?? ContinuousClock())
    }

    /// Runs the session to its end. Returns after `.ended` has been yielded. Cancelling it
    /// is a `disconnect()`.
    public func run() async {
        guard !started else { return }
        started = true
        // Cancelled before it ran is a disconnect too (the handler below only sees later ones).
        if Task.isCancelled { await disconnect() }
        // Disconnected before it ran: already ended, so never start ssh.
        guard !core.isFinished else {
            await shutdown?.value
            return
        }
        let endAwake = awake.begin()
        defer { endAwake() }
        // Not a child task: cancelling run() must not cancel the reader before Bye is sent.
        let reader = Task { await self.connectAndRead() }
        self.reader = reader
        await withTaskCancellationHandler {
            await reader.value
        } onCancel: {
            Task { await self.disconnect() }
        }
        await shutdown?.value
    }

    /// Says Bye and ends the session as `.disconnected`. Input sent before this goes first.
    /// `abandoningAQuietLink`: Reconnect Now, whose next try mustn't wait on a link that is
    /// interrupted now (`ByteConnection.abandon()`); a close or Disconnect closes only its own.
    public func disconnect(abandoningAQuietLink: Bool = false) async {
        if abandoningAQuietLink { abandonsQuietLink = true }
        // Still connecting: there's no Bye to send, so the connect (ssh -G, ssh) stops now.
        if connection == nil { reader?.cancel() }
        deliverInput(finishing: true)
        await perform(core.stop())
    }

    /// Records the raw stream for `duration`, from the next keyframe (asked for now).
    public func record(to directory: URL, for duration: Duration) async {
        // Installed before any await, so no frame or StreamConfig can slip past it.
        let previous = recorder
        recorder = StreamRecorder(directory: directory, duration: duration, now: .now, config: config)
        if core.state == .streaming { enqueue(.requestKeyframe) }
        await previous?.finish()
    }

    private func connectAndRead() async {
        // A cancellation's disconnect can land before the reader starts.
        guard !core.isFinished else { return }
        yield(.connecting)
        let connection: any ByteConnection
        do {
            connection = try await transport.connect()
        } catch {
            await perform(core.ended(by: error, afterFrames: 0))
            return
        }
        // Disconnected while connecting.
        guard !core.isFinished else {
            await connection.close()
            return
        }
        self.connection = connection
        writer = SessionWriter(connection: connection, observer: observer) { [weak self] error in
            await self?.writeFailed(error)
        }
        ticks = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: Self.tickInterval)
                await self?.tick()
            }
        }
        await perform(core.start())
        // Whatever was queued before now is judged now, held or not: a press before the stream is
        // dropped. Delivery judges what stays again, so this judges on a copy of the gate.
        inputs.keepInputs(
            inputGate.preview(streaming: core.state == .streaming, interrupted: liveness.isInterrupted))
        deliverInput()
        inputDrain = Task { [weak self, inputs] in
            for await _ in inputs.wakeups { await self?.deliverInput() }
        }
        startClipboard()
        do {
            for try await chunk in connection.incoming {
                if liveness.heard(at: Self.uptime()) { yield(.interrupted(false)) }
                parser.append(chunk)
                while !core.isFinished, let frame = try parser.next() {
                    try await handle(frame)
                }
                if core.isFinished { break }
            }
            await perform(core.ended(by: nil, afterFrames: parser.framesParsed))
        } catch {
            await perform(core.ended(by: error, afterFrames: parser.framesParsed))
        }
    }

    private func handle(_ frame: Frame) async throws {
        let message = try ServerMessage.decode(frame.body)
        observed(frame, message)
        if case .pong(let t, _) = message {
            liveness.answered(ping: t)
            pongHeard(t: t)
        }
        if case .streamConfig = message { config = frame }
        // A record() during the await may have installed a new recorder: keep that one.
        if let recorder, await !recorder.offer(frame: frame, message: message), self.recorder === recorder {
            self.recorder = nil
        }
        let actions = core.receive(message, payloadLength: frame.payload.count, now: Self.now())
        await perform(actions, frame: frame, message: message)
    }

    private func tick() async {
        await perform(core.tick(now: Self.now()))
        // A tick after the end (the loop's last, once cancelled) reports nothing.
        if !core.isFinished, liveness.check(at: Self.uptime()) { yield(.interrupted(true)) }
        await checkProbe()
    }

    private func writeFailed(_ error: any Error) async {
        await perform(core.ended(by: error, afterFrames: parser.framesParsed))
    }

    /// Carries out the core's actions in order. `frame` and `message` are the frame being
    /// handled, for `.decode` and `.deliver`.
    func perform(_ actions: [SessionAction], frame: Frame? = nil, message: ServerMessage? = nil) async {
        for action in actions {
            switch action {
            case .send(let message):
                if case .ping = message { liveness.pinged(at: Self.uptime()) }
                enqueue(message)
            case .configureDecoder(let config):
                pointer.publish(nil)
                loggedDecodeFailures.removeAll()
                do {
                    try await decoder.configure(config)
                } catch {
                    await perform(core.finish(.decoderFailed("\(error)")))
                    return
                }
                // Disconnected while configuring: the rest of this batch is moot.
                if core.isFinished { return }
            case .updateDecoder(let config):
                await decoder.update(config)
            case .cursorPosition(let x, let y, let visible):
                pointer.publish(.init(x: x, y: y, visible: visible))
            case .decode(let header):
                guard let frame else { continue }
                await decode(header, frame: frame)
            case .cursor(let shape):
                guard let frame else { continue }
                // Only the declared pixels: bytes past them are skipped (`checkPayload`).
                let image = CursorImage(shape, payload: Array(frame.payload.prefix(Int(shape.argbLength))))
                cursor.publish(image)
                if image == nil, !loggedInvalidCursor {
                    loggedInvalidCursor = true
                    Self.log.error(
                        "cursor shape not shown: \(shape.width)×\(shape.height), hotspot \(shape.hotX),\(shape.hotY), \(shape.argbLength) of \(frame.payload.count) bytes"
                    )
                }
            case .status(let status):
                yield(status)
            case .activate(let names):
                for name in names {
                    await features[name]?.activate(
                        FeatureContext { [weak self] body, payload in
                            await self?.send(body: body, payload: payload, type: name)
                        })
                }
            case .deliver(let name):
                guard let frame, case .unknown(let variant) = message else { continue }
                await features[name]?.receive(variant: variant, body: frame.body, payload: frame.payload)
            case .clipboard(let message):
                await receiveClipboard(message, payload: frame?.payload ?? [])
            case .finish(let end):
                beginShutdown(end)
            }
        }
    }

    /// Decodes one frame, timed, and acks it (`SessionCore.decoded`).
    private func decode(_ header: VideoFrameHeader, frame: Frame) async {
        let main = Int(header.dataLength)
        let aux = main + Int(header.auxLength)
        let clock = ContinuousClock()
        let start = clock.now
        let outcome = await decoder.decode(
            header, main: frame.payload[0..<main], aux: frame.payload[main..<aux])
        let elapsed = (clock.now - start).components
        switch outcome {
        case .failed(let reason):
            if loggedDecodeFailures.count < Self.maxLoggedDecodeFailures,
                loggedDecodeFailures.insert(reason).inserted
            {
                Self.log.error("decode failed: \(reason, privacy: .public)")
            }
        case .picture: loggedDecodeFailures.removeAll()
        case .noPicture: break
        }
        let milliseconds = Double(elapsed.seconds) * 1000 + Double(elapsed.attoseconds) / 1e15
        await perform(
            core.decoded(
                frameID: header.frameID, outcome: outcome, decodeMilliseconds: milliseconds, now: Self.now()))
    }

    /// Sends the queued input the gate admits, while the session can still write, up to a
    /// clipboard command, which is carried out before the input queued after it goes.
    /// `finishing`: everything queued goes, clipboard commands dropped.
    func deliverInput(finishing: Bool = false) {
        guard finishing || !carryingOut else { return }
        let taken = finishing ? inputs.takeAll() : inputs.take()
        guard writer != nil, !core.isFinished else { return answer(taken.fences) }
        let streaming = core.state == .streaming
        for input in taken.inputs
        where inputGate.admits(input, streaming: streaming, interrupted: liveness.isInterrupted) {
            enqueue(input.clientMessage)
        }
        fence(taken.fences)
        if let command = taken.command {
            carryingOut = true
            Task { await self.carryOut(command) }
        }
    }

    func yield(_ status: SessionStatus) {
        if let state = Self.describe(status) { Self.log.info("session \(state, privacy: .public)") }
        continuation.yield(status)
    }

    private func beginShutdown(_ end: SessionEnd) {
        guard shutdown == nil else { return }
        shutdown = Task { await self.close(end) }
    }

    /// Bye (if queued) goes out, then the connection closes and `.ended` is reported.
    private func close(_ end: SessionEnd) async {
        ticks?.cancel()
        resizeWake?.cancel()
        inputDrain?.cancel()
        // What close drops never goes: nothing need wait for its releases.
        answer(inputs.close())
        await closeClipboard()
        await writer?.drain(within: Self.drainLimit)
        // A link found dead, or quiet when Reconnect Now ends the session, is abandoned: the
        // next try mustn't wait on it.
        if linkLost || abandonsQuietLink && liveness.isInterrupted {
            await connection?.abandon()
        } else {
            await connection?.close()
        }
        // The server has handled all it will, and no Pong is coming.
        answer(fences.ended())
        await recorder?.finish()
        recorder = nil
        pointer.publish(nil)
        yield(.ended(end))
        continuation.finish()
    }

    /// Wall-clock milliseconds, as acks carry.
    static func now() -> UInt64 {
        UInt64(max(0, Date.now.timeIntervalSince1970 * 1000))
    }

    /// Monotonic milliseconds that stop while the Mac sleeps, for `Liveness`.
    static func uptime() -> UInt64 {
        UInt64((SuspendingClock.now - start) / .milliseconds(1))
    }

    private static let start = SuspendingClock.now

    /// The state a status reports, never its contents; nil for stats (once a second).
    private static func describe(_ status: SessionStatus) -> String? {
        switch status {
        case .connecting: "connecting"
        case .handshaking: "handshaking"
        case .waitingForVideo: "waiting for video"
        case .streaming: "streaming"
        case .pictureHeld(let on): on ? "picture held" : "picture shown"
        case .stats: nil
        case .interrupted(let on): on ? "interrupted" : "resumed"
        case .clipboardOffer, .clipboardActivity: nil
        case .ended: "ended"
        }
    }
}
