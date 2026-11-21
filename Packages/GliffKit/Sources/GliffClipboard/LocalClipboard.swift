/// What we offer from the Mac: the types the remote may ask for, the Mac clipboard's
/// `changeCount` the offer was made from, and whether a password manager marked the copy (it
/// then goes with KDE's marker). Files aren't shared.
public struct LocalClipboardOffer: Equatable, Sendable {
    public var mimeTypes: [String]
    public var token: Int
    public var isPassword: Bool

    public init(mimeTypes: [String], token: Int, isPassword: Bool = false) {
        (self.mimeTypes, self.token, self.isPassword) = (mimeTypes, token, isPassword)
    }
}

/// The app's side of a Mac offer: reads a type when the remote asks for it.
public protocol LocalClipboardSource: Sendable {
    /// The type's bytes, read from the clipboard whose `changeCount` is `token`: `.replaced` if
    /// it has moved since, `.tooLarge` over `ClipboardLimits.maxItem`, `.failed` if unreadable.
    func source(for mime: String, token: Int) async throws(TransferError) -> any ChunkSource
}
