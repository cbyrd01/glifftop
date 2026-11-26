public import GliffSFTP

/// One item of a host folder, as its listing gave it.
public struct RemoteEntry: Equatable, Sendable {
    public let name: RemoteName
    /// From the permissions' `S_IFMT` bits; nil when the host sent no permissions.
    public let kind: SFTPFileType?
    public let size: UInt64?
    /// Seconds since 1970.
    public let modified: UInt32?
    /// For a link: what it points to, from STAT; nil when not looked up or not found.
    public var linkTarget: SFTPFileType?

    public init(name: RemoteName, attributes: SFTPAttributes) {
        self.name = name
        kind = attributes.fileType
        size = attributes.size
        modified = attributes.times?.modification
    }
}
