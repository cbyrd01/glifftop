import Foundation
import GliffMachines
import GliffPorts
import GliffTransport
import Observation

/// The app's ports: one `PortsRegistry` on the shared connections, a hold on each active
/// session window's host with its machine's "Forward when connected" ports, each window's
/// `PortsModel`, and "Forward new ports automatically". The holds follow `OpenSessions` and
/// each model's session and machine (`withObservationTracking`).
@Observable final class AppPorts {
    static let shared = AppPorts()

    @ObservationIgnored let registry = PortsRegistry(connections: AppConnections.shared)

    /// "Forward new ports automatically", for every host, off at first; kept in `UserDefaults`.
    var automatic = UserDefaults.standard.bool(forKey: AppSettings.forwardNewPortsKey) {
        didSet {
            UserDefaults.standard.set(automatic, forKey: AppSettings.forwardNewPortsKey)
            registry.setAutomatic(automatic)
        }
    }

    private init() { registry.setAutomatic(automatic) }

    /// A window's ports, and its hold while its session is active.
    private struct Window {
        weak var session: SessionModel?
        let ports: PortsModel
        var holding: Holding?
    }

    @ObservationIgnored private var windows: [ObjectIdentifier: Window] = [:]
    @ObservationIgnored private var started = false

    /// `session`'s window's ports, made on first ask.
    func ports(for session: SessionModel) -> PortsModel { window(for: session).ports }

    private func window(for session: SessionModel) -> Window {
        let key = ObjectIdentifier(session)
        if let window = windows[key] {
            if window.session === session { return window }
            // A model gone before `track` saw it, its identifier reused: its hold and stream end.
            window.holding?.end()
            window.ports.follow(nil)
        }
        let window = Window(session: session, ports: PortsModel(registry: registry))
        window.ports.follow(Self.target(of: session))
        windows[key] = window
        return window
    }

    /// Follows the windows from now on: at launch, outside any view's update, so no view
    /// takes on what the holds read.
    func start() {
        guard !started else { return }
        started = true
        track()
    }

    /// Applies what the windows want now, and again on their next change.
    private func track() {
        let wanted = withObservationTracking {
            OpenSessions.shared.models.map { ($0, Self.target(of: $0), Self.saved($0.machine)) }
        } onChange: {
            Task { @MainActor in AppPorts.shared.track() }
        }
        var open = Set<ObjectIdentifier>()
        for (session, target, saved) in wanted {
            let key = ObjectIdentifier(session)
            open.insert(key)
            var window = window(for: session)
            window.ports.follow(target)
            if let holding = window.holding, holding.target == target {
                holding.update(saved)
            } else {
                window.holding?.end()
                window.holding = target.map { Holding(registry: registry, target: $0, saved: saved) }
            }
            windows[key] = window
        }
        // A window not open (closed, or not yet added) holds nothing; its ports are kept for
        // its views until its model is gone.
        for (key, window) in windows where !open.contains(key) {
            window.holding?.end()
            window.ports.follow(nil)
            var idle = window
            idle.holding = nil
            windows[key] = window.session == nil ? nil : idle
        }
    }

    /// The host whose ports `session`'s window shows: its destination while active.
    private static func target(of session: SessionModel) -> SSHTarget? {
        session.isActive ? session.destination : nil
    }

    /// A machine's "Forward when connected" ports as forwards: each on its last Mac port, else
    /// where the chooser starts.
    private static func saved(_ machine: Machine?) -> [PortForward] {
        (machine?.options.forwards ?? []).compactMap {
            PortForward(
                localPort: $0.localPort ?? LocalPortChooser.start(for: $0.remotePort),
                destination: $0.forwardDestination, remotePort: $0.remotePort)
        }
    }
}

/// One window's hold on its host's ports, its calls made in order.
private final class Holding {
    let target: SSHTarget
    private var saved: [PortForward]
    private let hold: Task<PortsHold, Never>
    private var last: Task<Void, Never>?

    init(registry: PortsRegistry, target: SSHTarget, saved: [PortForward]) {
        (self.target, self.saved) = (target, saved)
        hold = Task { await registry.hold(target, saved: saved) }
    }

    func update(_ saved: [PortForward]) {
        guard saved != self.saved else { return }
        self.saved = saved
        after { await $0.update(saved: saved) }
    }

    func end() { after { await $0.end() } }

    private func after(_ call: @escaping (PortsHold) async -> Void) {
        let (hold, previous) = (hold, last)
        last = Task {
            await previous?.value
            await call(hold.value)
        }
    }
}
