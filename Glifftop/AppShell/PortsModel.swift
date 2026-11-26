import Foundation
import GliffPorts
import GliffTransport
import Observation

/// One window's view of its host's ports (`AppPorts`): the latest snapshot, which offers the
/// popover has shown, whether the popover or the sheet is open, and the actions on the host's
/// forwards, which all its windows share.
@Observable final class PortsModel {
    private(set) var snapshot = PortsSnapshot()
    var showsPopover = false
    /// Show Ports while the toolbar isn't shown.
    var showsSheet = false
    /// The Available ports the popover has shown: the toolbar's dot is for the others.
    private var seen: Set<Int> = []

    @ObservationIgnored private let registry: PortsRegistry
    @ObservationIgnored private var target: SSHTarget?
    @ObservationIgnored private var following: Task<Void, Never>?

    init(registry: PortsRegistry) { self.registry = registry }

    /// Forwards listening on this Mac now: the toolbar's badge.
    var activeCount: Int {
        snapshot.forwarded.count {
            if case .active = $0.state { true } else { false }
        }
    }

    var hasUnseenOffer: Bool { snapshot.available.contains { !seen.contains($0.port) } }

    /// The popover shows the Available ports.
    func markSeen() {
        guard hasUnseenOffer else { return }
        seen.formUnion(snapshot.available.map(\.port))
    }

    /// Shows `target`'s ports from now on, or none.
    func follow(_ target: SSHTarget?) {
        guard target != self.target else { return }
        self.target = target
        following?.cancel()
        following = nil
        (snapshot, seen) = (PortsSnapshot(), [])
        guard let target else {
            (showsPopover, showsSheet) = (false, false)
            return
        }
        let snapshots = registry.snapshots(for: target)
        following = Task { [weak self] in
            for await snapshot in snapshots { self?.snapshot = snapshot }
        }
    }

    func forward(_ port: RemotePort) {
        withPorts { await $0.forward(remote: port.port, destination: port.destination, localPort: nil) }
    }

    /// Forward a Port…: `remote` on the host itself, on `localPort` alone when typed.
    func forward(remote: Int, localPort: Int?) {
        withPorts { await $0.forward(remote: remote, destination: .localhost, localPort: localPort) }
    }

    func stop(_ row: ForwardRow) { withPorts { await $0.stop(row.id) } }

    func retry(_ row: ForwardRow) { withPorts { await $0.retry(row.id) } }

    func ignore(_ port: Int) { withPorts { await $0.ignore(port) } }

    func dismiss(_ notice: PortNotice) { withPorts { await $0.dismiss(notice) } }

    private func withPorts(_ act: @escaping @Sendable (HostPorts) async -> Void) {
        guard let target else { return }
        let registry = registry
        Task {
            guard let ports = await registry.ports(for: target) else { return }
            await act(ports)
        }
    }
}
