/// Upstream's clipboard limits (gliff-proto `clipboard.rs`, gliff-transport `clipboard/mod.rs`),
/// exact: the server closes the session on a chunk larger than `chunk`.
public enum ClipboardLimits {
    /// The largest `dataLength` of one `Data` message.
    public static let chunk = 262_144
    /// Chunks a sender may have outstanding before it waits for an `Ack`.
    public static let window = 4
    /// The cap on a single item.
    public static let maxItem: UInt64 = 33_554_432
    /// A transfer with no chunk for this long is given up.
    public static let idleTimeout = Duration.seconds(30)
}
