/// A rule the host's bytes broke. Each one ends the sftp session.
public enum SFTPError: Error, Equatable, Sendable {
    /// A packet longer than `SFTPFramer.maxPacketLength`.
    case packetTooLong
    /// A packet shorter than its type and id.
    case packetTooShort
    /// The first packet wasn't VERSION: the login shell printed text before the server started.
    case textBeforeVersion
    /// A field runs past the end of its packet.
    case truncated
    /// A string longer than its field allows (a name, an extension).
    case stringTooLong
    /// A NAME reply's count is larger than its bytes can hold.
    case nameCountTooLarge
    /// VERSION named a version other than 3.
    case unsupportedVersion
    /// A VERSION or an ATTRS listed more than 64 name-and-value pairs.
    case tooManyExtensions
    /// Attributes with a flag v3 doesn't define, so their length is unknown.
    case unknownAttributeFlags
    /// A reply of a type no request is answered with.
    case unexpectedType(UInt8)
}
