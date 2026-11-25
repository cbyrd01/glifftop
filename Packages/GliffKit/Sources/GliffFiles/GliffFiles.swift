import os

/// The ssh subsystem the client speaks to.
public enum SFTPSubsystem {
    public static let name = "sftp"
}

/// The module's log: counts, byte totals, kinds and outcomes only. Never a file name, a path,
/// a single item's size, host text or a socket path.
enum FilesLog {
    static let logger = Logger(subsystem: "me.cbyrd.Glifftop", category: "GliffFiles")
}
