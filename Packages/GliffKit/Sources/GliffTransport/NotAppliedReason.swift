/// Why a forward line of the config (`SSHResolvedConfig.notAppliedLines`) isn't applied, as the
/// person is told.
public enum NotAppliedReason: Equatable, Sendable {
    /// A `LocalForward` on a Mac port under 1024.
    case privilegedPort
    /// Any other: a `RemoteForward` or `DynamicForward`, a unix socket, a destination a forward
    /// can't hold.
    case other

    public init(line: String) {
        let words = line.split(separator: " ", maxSplits: 1)
        let local = words.count == 2 && words[0].lowercased() == "localforward" ? words.last : nil
        let port = local.flatMap(SSHLocalForward.init(resolved:))?.port
        self = port.map { $0 < PortForward.localPorts.lowerBound } == true ? .privilegedPort : .other
    }
}
