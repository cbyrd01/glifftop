/// One encoded picture as gliff-server sends it: its NAL units, each from its header byte.
public struct AccessUnit: Equatable, Sendable {
    public let units: [[UInt8]]

    /// The Annex B bytes: each unit behind a 4-byte start code.
    public var annexB: [UInt8] { units.flatMap { [0, 0, 0, 1] + $0 } }

    /// Each unit's `nal_unit_type`.
    public var types: [UInt8] { units.compactMap { $0.first.map { $0 & 0x1F } } }
}
