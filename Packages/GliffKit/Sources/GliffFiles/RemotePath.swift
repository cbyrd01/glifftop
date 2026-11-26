/// An absolute path on the host, as names. Joining takes only a validated `RemoteName` and
/// going up trims the last component, so a path Glifftop builds never holds `..`.
public struct RemotePath: Hashable, Sendable {
    public let components: [RemoteName]

    public static let root = RemotePath(components: [])

    /// A path the host gave (a realpath, the folders command): absolute, each component a
    /// `RemoteName` (so no NUL and no `..`). Empty and `.` components are dropped.
    public init?(absolute bytes: [UInt8]) {
        guard bytes.first == 0x2F else { return nil }
        var components: [RemoteName] = []
        for part in bytes.split(separator: 0x2F) where part != [0x2E] {
            guard let name = RemoteName(raw: Array(part)) else { return nil }
            components.append(name)
        }
        self.init(components: components)
    }

    private init(components: [RemoteName]) {
        self.components = components
    }

    /// The path as the host takes it: `/` and the components joined by `/`.
    public var raw: [UInt8] {
        guard !components.isEmpty else { return [0x2F] }
        var raw: [UInt8] = []
        raw.reserveCapacity(components.reduce(0) { $0 + 1 + $1.raw.count })
        for name in components {
            raw.append(0x2F)
            raw.append(contentsOf: name.raw)
        }
        return raw
    }

    /// The last component; nil for `/`.
    public var name: RemoteName? { components.last }

    /// The folder holding this path; `/` for `/`.
    public var parent: RemotePath { RemotePath(components: components.dropLast()) }

    public func appending(_ name: RemoteName) -> RemotePath {
        RemotePath(components: components + [name])
    }
}

/// A path is kept as its bytes, and read back under the same rules as a path the host gave.
extension RemotePath: Codable {
    public init(from decoder: any Decoder) throws {
        let raw = try decoder.singleValueContainer().decode([UInt8].self)
        guard let path = RemotePath(absolute: raw) else {
            throw DecodingError.dataCorrupted(
                .init(codingPath: decoder.codingPath, debugDescription: "not a path"))
        }
        self = path
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(raw)
    }
}
