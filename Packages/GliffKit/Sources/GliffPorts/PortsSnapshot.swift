public import GliffTransport

/// One forward of a host's, for as long as its `HostPorts` lives.
public struct ForwardID: Hashable, Sendable {
    let value: Int
}

/// Where a forward came from.
public enum ForwardKind: Equatable, Sendable {
    /// The person's ssh_config (`LocalForward`).
    case config
    /// The machine's "Forward when connected" ports.
    case saved
    /// Made this session.
    case manual
    /// Made by "Forward new ports automatically".
    case automatic
}

/// Why a forward isn't active.
public enum ForwardFailure: Equatable, Sendable {
    /// The Mac's port is in use (the check found it taken, or ssh couldn't bind it).
    case localPortInUse
    /// ssh refused the forward, or didn't answer twice.
    case failed
}

public enum ForwardState: Equatable, Sendable {
    /// Listening on this Mac's `local` port.
    case active(local: Int, loopbacks: Loopbacks)
    /// No connection to apply it on.
    case waiting
    case failed(ForwardFailure)
    case stopping
}

/// Whether the host's listening ports are being followed.
public enum PortDetection: Equatable, Sendable {
    case running
    /// Not attached to a connection: not yet, or no longer.
    case idle
    /// The host can't list them (no `/proc`).
    case unavailable
    /// The watcher failed five times in a row and gave up until the next attachment.
    case stopped
    /// The connection has no free place for the watcher.
    case waitingForPlace
}

/// One row of the Forwarded list.
public struct ForwardRow: Equatable, Sendable, Identifiable {
    public let id: ForwardID
    public let kind: ForwardKind
    /// The Mac port it has, or last had, or asks for.
    public let localPort: Int?
    public let remotePort: Int
    public let destination: ForwardDestination
    /// The listening process's name on the host (display only).
    public let name: String?
    public let state: ForwardState
    /// The host has the port listening (as far as the watcher knows).
    public let listening: Bool
    /// A config forward whose bind address isn't loopback: it is bound on loopback only.
    public let bindNotLoopback: Bool
}

/// What a host's ports look like now, for the toolbar item and the popover.
public struct PortsSnapshot: Equatable, Sendable {
    public var forwarded: [ForwardRow] = []
    public var available: [RemotePort] = []
    public var other: [RemotePort] = []
    /// The ssh_config's forward lines not applied (display only, never logged).
    public var notApplied: [String] = []
    public var detection: PortDetection = .idle
    public var notices: [PortNotice] = []

    public init() {}
}
