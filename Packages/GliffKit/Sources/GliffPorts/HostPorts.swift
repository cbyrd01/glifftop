public import GliffTransport

/// One host's forwards, kept while a window holds them (`PortsRegistry`).
///
/// - Its work runs one pass at a time (`settle`): attaching, applying, and the end of the
///   grace. A change during a pass makes it go round again.
/// - It attaches a passive lease on its first hold and at each `.opened` while it has none:
///   it never opens a connection, asks a sign-in or keeps one open.
/// - Attached, it applies its forwards one at a time: config, saved, then those made this
///   session. A lost connection makes them `.waiting` until it attaches again, at once when
///   another connection lives, else at the next `.opened`.
/// - Re-applied, a forward takes its old Mac port when free, else the chooser's, with a
///   `.moved` notice.
/// - Attached, it runs the watcher on a spare place (`HostPorts+Watcher`) and offers the new
///   ports it reports (`HostPorts+Offers`).
/// - 10 s after the last hold ends it cancels every forward, ends its lease and is dropped.
/// - Logs counts only: never a port, address, destination, name or config line.
public actor HostPorts {
    /// One forward, as kept.
    struct Entry {
        let id: ForwardID
        let kind: ForwardKind
        let destination: ForwardDestination
        let remotePort: Int
        /// The Mac port it asks for first: remembered (saved), typed or configured.
        let wanted: Int?
        /// Tried alone, never moved: a config forward's port, or one the person typed.
        let exact: Bool
        /// A config forward's bind address isn't loopback.
        var bindNotLoopback = false
        /// What the window says of it: forwarded automatically, or moved.
        var notice: PortNotice?
        /// The Mac port it has, or last had.
        var local: Int?
        var state: ForwardState = .waiting
    }

    public nonisolated let target: SSHTarget
    let connections: HostConnections
    let clock: any Clock<Duration>
    let chooser: LocalPortChooser
    private let publishSnapshot: @Sendable (PortsSnapshot) -> Void
    private let finished: @Sendable (HostPorts) async -> Void
    static let grace = Duration.seconds(10)

    var entries: [Entry] = []
    var nextID = 0
    var lease: PassiveLease?
    var notApplied: [String] = []
    /// The grace has run out: the pass under way is the last.
    var expiring = false
    private var holds: [Int: [PortForward]] = [:]
    /// A window holds these ports.
    var isHeld: Bool { !holds.isEmpty }
    private var settling = false
    private var again = false
    private var subscribed = false
    private var events: Task<Void, Never>?
    private var graceTask: Task<Void, Never>?
    private(set) var isFinished = false
    /// Which grace is running: an earlier one that ends late changes nothing.
    private var grace = 0
    // The watcher and the offers.
    var detection = PortDetection.idle
    var watcher: Task<Void, Never>?
    /// A place was freed while the watcher waited for one, or was still ending.
    var placeWasFreed = false
    /// The latest frame, while the watcher reads them.
    var frame: PortFrame?
    /// The ports of this attachment's last frame; nil before its first, which is silent.
    var known: Set<Int>?
    /// New Available ports with a notice, oldest first.
    var offered: [RemotePort] = []
    /// The ports of offers not answered when the watcher stopped: offered again when a frame
    /// shows them, even a first.
    var unanswered: Set<Int> = []
    var ignored: Set<Int> = []
    private let automaticSetting: AutomaticSetting
    var automatic: Bool { automaticSetting.isOn }
    /// Automatic forwards whose port is gone, each with the timer that stops it.
    var absent: [ForwardID: Task<Void, Never>] = [:]
    /// The cancels of each forward being stopped.
    var stops: [ForwardID: Task<Bool, Never>] = [:]

    /// Waiting for it to end; nil once it has.
    var endWaiters: [CheckedContinuation<Void, Never>]? = []

    init(
        target: SSHTarget, connections: HostConnections, clock: any Clock<Duration>,
        chooser: LocalPortChooser, publish: @escaping @Sendable (PortsSnapshot) -> Void,
        automatic: AutomaticSetting, finished: @escaping @Sendable (HostPorts) async -> Void
    ) {
        (self.target, self.connections, self.clock, self.chooser) = (target, connections, clock, chooser)
        (publishSnapshot, automaticSetting, self.finished) = (publish, automatic, finished)
    }

    func publish() {
        guard !isFinished else { return }
        publishSnapshot(snapshot)
    }

    /// Attaches when it has no lease, then applies the waiting forwards, or ends once the grace
    /// has run out; a call during a pass makes that pass go round again.
    func settle() async {
        again = true
        guard !settling else { return }
        settling = true
        defer { settling = false }
        while again, !isFinished {
            again = false
            if expiring {
                await expire()
            } else {
                if lease == nil { await attach() }
                await drain()
            }
        }
    }

    // MARK: Holds

    /// False once the grace has run out, after its forwards are cancelled and it is dropped:
    /// the registry makes a new HostPorts, which finds their Mac ports free.
    func addHold(_ id: Int, saved: [PortForward]) async -> Bool {
        guard !isFinished else {
            await untilEnded()
            return false
        }
        graceTask?.cancel()
        (graceTask, expiring) = (nil, false)
        holds[id] = saved
        addSaved(saved)
        if !subscribed {
            subscribed = true
            let stream = await connections.events(for: target)
            if !isFinished {
                events = Task { [weak self] in
                    for await event in stream { await self?.handle(event) }
                }
            }
        }
        await settle()
        return true
    }

    private func untilEnded() async {
        guard endWaiters != nil else { return }
        await withCheckedContinuation { endWaiters?.append($0) }
    }

    func updateHold(_ id: Int, saved: [PortForward]) async {
        guard holds[id] != nil else { return }
        holds[id] = saved
        addSaved(saved)
        await settle()
    }

    func removeHold(_ id: Int) {
        guard holds.removeValue(forKey: id) != nil, !isHeld, !isFinished else { return }
        grace += 1
        graceTask = Task { [clock, grace] in
            guard (try? await clock.sleep(for: Self.grace)) != nil else { return }
            await self.graceEnded(grace)
        }
    }

    private func graceEnded(_ generation: Int) async {
        guard generation == grace, !isHeld, !isFinished else { return }
        expiring = true
        await settle()
    }

    /// Saved forwards are kept until the last hold ends: a port already forwarded isn't added
    /// again.
    private func addSaved(_ saved: [PortForward]) {
        let count = entries.count
        for forward in saved
        where !entries.contains(where: { $0.forwards(forward.destination, forward.remotePort) }) {
            entries.append(
                Entry(
                    id: newID(), kind: .saved, destination: forward.destination,
                    remotePort: forward.remotePort, wanted: forward.localPort, exact: false))
        }
        guard entries.count != count else { return }
        dropTakenOffers()
        publish()
    }

    private func expire() async {
        isFinished = true
        events?.cancel()
        // Its channel closes before the lease gives back the watcher's place.
        let watching = watcher
        endWatch()
        await watching?.value
        for stop in stops.values { _ = await stop.value }
        var cancelled = 0
        var refused = 0
        if let lease {
            for entry in entries {
                guard case .active(let local, let loopbacks) = entry.state,
                    let forward = entry.forward(local: local)
                else { continue }
                if await Self.cancel(forward, loopbacks, on: lease) { cancelled += 1 } else { refused += 1 }
            }
            await lease.end()
        }
        lease = nil
        HostPortsLog.ended(forwards: cancelled)
        if refused > 0 { HostPortsLog.refused(cancels: refused) }
        entries = []
        await finished(self)
        for waiter in endWaiters ?? [] { waiter.resume() }
        endWaiters = nil
    }

    // MARK: Connections

    private func handle(_ event: ConnectionEvent) async {
        guard !isFinished else { return }
        switch event {
        case .opened:
            if lease == nil { await settle() }
        case .ended(let id, _):
            if id == lease?.connectionID { detach() }
            if lease == nil { await settle() }
        case .placeFreed(let id):
            guard id == lease?.connectionID else { return }
            placeWasFreed = true
            if watcher == nil, detection == .waitingForPlace { startWatcher() }
        }
    }

    /// Lets go of a lost connection. The master took its listeners with it: forwards wait for
    /// the next, a failed one stays failed, and one being stopped is not applied again.
    func detach() {
        lease = nil
        endWatch()
        var waiting = 0
        for index in entries.indices {
            switch entries[index].state {
            case .failed, .stopping: continue
            case .active, .waiting: entries[index].state = .waiting
            }
            waiting += 1
        }
        HostPortsLog.waiting(forwards: waiting)
        publish()
    }

    /// Attaches to the host's live connection, if any, and takes its config forwards.
    private func attach() async {
        guard isHeld, let attached = await connections.attach(to: target) else { return }
        lease = attached
        let configured = await attached.configuredForwards
        guard lease === attached else { return }
        // Config forwards come back on each attachment, a stopped one included.
        let config = configured.local.map { line in
            var entry = Entry(
                id: newID(), kind: .config, destination: line.forward.destination,
                remotePort: line.forward.remotePort, wanted: line.forward.localPort, exact: true)
            entry.bindNotLoopback = !Self.isLoopbackBind(line.bind)
            return entry
        }
        // A saved port the config forwards is kept once, as the config's.
        entries =
            config
            + entries.filter { entry in
                entry.kind != .config
                    && !(entry.kind == .saved
                        && config.contains { $0.forwards(entry.destination, entry.remotePort) })
            }
        notApplied = configured.notApplied
        dropTakenOffers()
        publish()
        startWatcher()
    }

    /// A bind address that is loopback, or none (ssh's default, loopback). An empty one is
    /// every interface, as `*` is.
    static func isLoopbackBind(_ bind: String?) -> Bool {
        guard let bind else { return true }
        return ForwardDestination(configuredHost: bind)?.isLoopback ?? false
    }

    func newID() -> ForwardID {
        nextID += 1
        return ForwardID(value: nextID)
    }
}
