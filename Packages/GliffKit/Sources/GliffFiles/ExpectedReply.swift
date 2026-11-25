import GliffSFTP

/// The shape of reply a request takes, checked as each reply arrives. A STATUS other than OK
/// answers any request; OK answers only a request that takes no value.
enum ExpectedReply {
    case statusOnly
    case handle
    /// DATA of 1 to this many bytes.
    case data(upTo: Int)
    /// A NAME of at least one entry.
    case names
    /// A NAME of exactly one entry.
    case oneName
    case attributes
    case extendedReply

    init(_ request: SFTPRequest) {
        self =
            switch request {
            case .open, .opendir: .handle
            case .read(_, _, let length): .data(upTo: Int(length))
            case .readdir: .names
            case .realpath, .readlink: .oneName
            case .lstat, .fstat, .stat: .attributes
            case .statvfs, .limits: .extendedReply
            case .initialize, .close, .write, .setstat, .fsetstat, .remove, .mkdir, .rmdir, .rename,
                .posixRename, .fsync:
                .statusOnly
            }
    }

    /// Whether `reply` has this shape.
    func allows(_ reply: SFTPReply) -> Bool {
        switch (self, reply) {
        case (.statusOnly, .status): true
        case (_, .status(_, let code)): code != .ok
        case (.handle, .handle), (.attributes, .attributes), (.extendedReply, .extendedReply): true
        case (.data(let most), .data(_, let bytes)): !bytes.isEmpty && bytes.count <= most
        case (.names, .name(_, let entries)): !entries.isEmpty
        case (.oneName, .name(_, let entries)): entries.count == 1
        default: false
        }
    }
}
