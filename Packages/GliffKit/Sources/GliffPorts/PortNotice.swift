/// Something a session window shows until it is dismissed, or until its port goes.
public enum PortNotice: Hashable, Sendable {
    /// A new port listens on the host: "Port 5173 is listening on omarchy (node)".
    case listening(port: Int, name: String?)
    /// New ports at once, or before the last was answered: "3 ports are listening on omarchy".
    case several(ports: [Int])
    /// The automatic setting forwarded a new port: "Port 5173 is forwarded to localhost:5173".
    /// It goes when the forward stops.
    case forwarded(id: ForwardID, remote: Int, local: Int)
    /// A forward came back on another Mac port: "Port 5173 is now forwarded to
    /// localhost:5174". A browser tab on the old one is stale.
    case moved(id: ForwardID, remote: Int, from: Int, to: Int)
}
