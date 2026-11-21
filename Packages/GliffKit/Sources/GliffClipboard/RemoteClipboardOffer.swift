/// What the remote offers: its types, fetched only when pasted on the Mac. Files aren't shared:
/// a file list it carries is dropped, noting only that there was one.
public struct RemoteClipboardOffer: Equatable, Sendable {
    public var serial: UInt32
    public var mimeTypes: [String]
    /// The remote copied files: nothing of them comes to the Mac, but the host's clipboard holds
    /// something the person chose there, unlike a cleared one.
    public var hasFiles: Bool
    /// The session's first offer: the server reports the host's clipboard as it was at connect,
    /// which never comes to the Mac.
    public var isFirst: Bool

    public init(serial: UInt32, mimeTypes: [String], hasFiles: Bool = false, isFirst: Bool = false) {
        (self.serial, self.mimeTypes, self.hasFiles, self.isFirst) = (serial, mimeTypes, hasFiles, isFirst)
    }

    /// Nothing to paste: no type but the password hint.
    public var isEmpty: Bool { mimeTypes.allSatisfy { $0 == ClipboardMimes.passwordHint } }

    /// It holds something the Mac takes: text, HTML or PNG.
    public var isPasteable: Bool {
        mimeTypes.contains {
            ClipboardMimes.isText($0) || $0 == ClipboardMimes.html || $0 == ClipboardMimes.png
        }
    }

    /// The remote marked it as a password (KDE's hint), so Mac clipboard managers should skip it.
    public var isPassword: Bool { mimeTypes.contains(ClipboardMimes.passwordHint) }
}
