/// Why a frame or message could not be decoded, or (for the size limits) could not be sent.
public enum ProtocolError: Error, Equatable, Sendable {
    /// The input ended before the item did, or a length or count exceeds the bytes left.
    case truncated
    /// The item has the wrong CBOR type. `found` is its initial byte.
    case unexpectedType(expected: String, found: UInt8)
    /// An integer doesn't fit the field's type.
    case integerOverflow
    /// A text string is not valid UTF-8.
    case invalidUTF8
    /// An enum field holds a value this client doesn't know.
    case unknownEnumValue(type: String, value: Int64)
    /// A message has fewer fields than its type requires.
    case missingField(message: String, index: Int)
    /// A frame's body is over the protocol limit, whether the peer announced it or we built it.
    case bodyTooLarge(UInt32)
    /// A frame's total payload, or one payload a message declares, is over the protocol
    /// limit, whoever built it.
    case payloadTooLarge(UInt32)
    /// A message declares more payload bytes than its frame carries.
    case payloadOverrun(declared: UInt64, carried: UInt64)
}
