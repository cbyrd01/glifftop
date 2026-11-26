public import GliffTransport
import os

/// Making, stopping and applying forwards, one at a time.
extension HostPorts {
    /// Forwards `remote` on the host to a Mac port: `localPort` alone when the person typed
    /// one (it fails when taken), else the chooser's. Nil once these ports have ended: the
    /// registry has others for the host.
    @discardableResult
    public func forward(remote: Int, destination: ForwardDestination, localPort: Int?) async -> ForwardID? {
        guard !isFinished else { return nil }
        let id = newID()
        entries.append(
            Entry(
                id: id, kind: .manual, destination: destination, remotePort: remote, wanted: localPort,
                exact: localPort != nil))
        publish()
        await settle()
        return id
    }

    /// Cancels a forward on its loopbacks and removes it. A config forward comes back on the
    /// next attachment.
    public func stop(_ id: ForwardID) async {
        guard let index = entries.firstIndex(where: { $0.id == id }) else { return }
        let entry = entries[index]
        guard case .active(let local, let loopbacks) = entry.state, let lease,
            let forward = entry.forward(local: local)
        else {
            entries.remove(at: index)
            publish()
            return
        }
        entries[index].state = .stopping
        publish()
        await Self.cancel(forward, loopbacks, on: lease)
        entries.removeAll { $0.id == id }
        publish()
    }

    /// Applies a failed forward again.
    public func retry(_ id: ForwardID) async {
        guard let index = entries.firstIndex(where: { $0.id == id }), case .failed = entries[index].state
        else { return }
        entries[index].state = .waiting
        publish()
        await settle()
    }

    /// Dismisses a notice.
    public func dismiss(_ notice: PortsNotice) {
        notices.removeAll { $0 == notice }
        publish()
    }

    /// Applies the waiting forwards one at a time, config first, then saved, then those made
    /// this session; returns once none is left, the connection is gone or the grace has run out.
    func drain() async {
        var applied = 0
        while !expiring, let lease,
            let next = Self.order.lazy.compactMap({ kind in
                self.entries.first { $0.kind == kind && $0.state == .waiting }
            }).first
        {
            guard let outcome = await apply(next, on: lease) else {
                // Lost without an end announced: it attaches again at the next open or end.
                if self.lease === lease { detach() }
                break
            }
            if outcome { applied += 1 }
        }
        if applied > 0 { HostPortsLog.applied(applied, of: entries) }
    }

    static let order: [ForwardKind] = [.config, .saved, .manual, .automatic]

    /// Applies one forward on `lease`: true when it became active, false when it failed or
    /// was stopped meanwhile, nil when the connection is gone (it stays `.waiting`).
    private func apply(_ entry: Entry, on lease: PassiveLease) async -> Bool? {
        let made = await make(entry, on: lease)
        let index = entries.firstIndex { $0.id == entry.id }
        guard self.lease === lease, let index else {
            // Stopped, or its connection ended, while it was applied: what was made goes, and
            // a forward still kept is applied on the next connection.
            if case .success(let choice) = made, let forward = entry.forward(local: choice.port) {
                await Self.cancel(forward, choice.loopbacks, on: lease)
            }
            return index == nil ? false : nil
        }
        switch made {
        case .success(let choice):
            if let old = entries[index].local, old != choice.port {
                notices.append(.moved(from: old, to: choice.port))
            }
            entries[index].local = choice.port
            entries[index].state = .active(local: choice.port, loopbacks: choice.loopbacks)
        case .failure(.connectionLost):
            entries[index].state = .waiting
        case .failure(.localPortInUse):
            entries[index].state = .failed(.localPortInUse)
        case .failure:
            entries[index].state = .failed(.failed)
        }
        publish()
        if case .failure(.connectionLost) = made { return nil }
        return made.isSuccess
    }

    /// Chooses a Mac port and forwards it on 127.0.0.1, then ::1. A port ssh finds taken since
    /// the check (not a config or typed one) gives one more choice, from the next port.
    private func make(_ entry: Entry, on lease: PassiveLease) async -> Result<Choice, ForwardError> {
        var skipping = entry.kind == .automatic ? AutomaticPortPolicy.databasePorts : []
        var from = entry.local ?? entry.wanted
        for attempt in 1...2 {
            guard let choice = await Self.choose(entry, from: from, skipping: skipping, chooser) else {
                return .failure(.localPortInUse)
            }
            guard let forward = entry.forward(local: choice.port) else { return .failure(.failed) }
            switch await Self.request(forward, on: .ipv4, lease) {
            case nil:
                guard choice.loopbacks == .both else { return .success(choice) }
                switch await Self.request(forward, on: .ipv6, lease) {
                case nil: return .success(choice)
                case .connectionLost: return .failure(.connectionLost)
                default: return .success(Choice(port: choice.port, loopbacks: .ipv4Only))
                }
            case .localPortInUse where !entry.exact && attempt == 1:
                (from, skipping) = (choice.port + 1, skipping.union([choice.port]))
            case let error?:
                return .failure(error)
            }
        }
        return .failure(.localPortInUse)
    }

    typealias Choice = LocalPortChooser.Choice

    /// The loopback checks bind sockets and may wait: off the actor.
    @concurrent
    private nonisolated static func choose(
        _ entry: Entry, from: Int?, skipping: Set<Int>, _ chooser: LocalPortChooser
    ) async -> Choice? {
        if entry.exact { return entry.wanted.flatMap(chooser.exactly) }
        return chooser.choose(remote: entry.remotePort, remembered: from, skipping: skipping)
    }

    /// One request, retried once after `.timedOut`. A forward that timed out may have been
    /// made, so it is cancelled before the retry and after the last.
    private static func request(_ forward: PortForward, on loopback: Loopback, _ lease: PassiveLease) async
        -> ForwardError?
    {
        for attempt in 1...2 {
            do {
                try await lease.forward(forward, on: loopback)
                return nil
            } catch .timedOut {
                try? await lease.cancel(forward, on: loopback)
                if attempt == 2 { return .timedOut }
            } catch {
                return error
            }
        }
        return .timedOut
    }

    /// Cancels `forward` on the loopbacks it holds.
    static func cancel(_ forward: PortForward, _ loopbacks: Loopbacks, on lease: PassiveLease) async {
        try? await lease.cancel(forward, on: .ipv4)
        if loopbacks == .both { try? await lease.cancel(forward, on: .ipv6) }
    }
}

extension HostPorts.Entry {
    /// Whether it forwards `remotePort` at `destination`.
    func forwards(_ destination: ForwardDestination, _ remotePort: Int) -> Bool {
        self.destination == destination && self.remotePort == remotePort
    }

    /// The forward at Mac port `local`.
    func forward(local: Int) -> PortForward? {
        PortForward(localPort: local, destination: destination, remotePort: remotePort)
    }
}

extension Result {
    fileprivate var isSuccess: Bool {
        if case .success = self { true } else { false }
    }
}

/// HostPorts' log lines: counts and kinds only.
enum HostPortsLog {
    static func applied(_ count: Int, of entries: [HostPorts.Entry]) {
        let failed = entries.filter { if case .failed = $0.state { true } else { false } }.count
        GliffPorts.log.info(
            "forwards applied: \(count, privacy: .public), failed: \(failed, privacy: .public)")
    }

    static func waiting(forwards count: Int) {
        GliffPorts.log.info("connection ended: \(count, privacy: .public) forwards waiting")
    }

    static func ended(forwards count: Int) {
        GliffPorts.log.info("ports released: \(count, privacy: .public) forwards cancelled")
    }
}
