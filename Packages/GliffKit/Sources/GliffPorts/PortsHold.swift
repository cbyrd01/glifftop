public import GliffTransport
import Synchronization

/// A window's hold on its host's ports: while any hold lives, the host's forwards are kept.
/// It carries the window's saved forwards; `end()` is safe to call more than once, and a hold
/// let go without it ends all the same.
public final class PortsHold: Sendable {
    let ports: HostPorts
    private let id: Int
    private let ended = Mutex(false)

    init(ports: HostPorts, id: Int) { (self.ports, self.id) = (ports, id) }

    /// The window's saved forwards changed: new ones are applied; ones dropped stay until the
    /// last hold ends.
    public func update(saved: [PortForward]) async {
        guard !hasEnded else { return }
        await ports.updateHold(id, saved: saved)
    }

    public func end() async {
        let first = ended.withLock { ended in
            defer { ended = true }
            return !ended
        }
        guard first else { return }
        await ports.removeHold(id)
    }

    private var hasEnded: Bool { ended.withLock { $0 } }

    deinit {
        guard !hasEnded else { return }
        let (ports, id) = (ports, id)
        Task { await ports.removeHold(id) }
    }
}
