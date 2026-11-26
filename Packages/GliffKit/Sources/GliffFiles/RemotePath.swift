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
        components.isEmpty ? [0x2F] : components.flatMap { [0x2F] + $0.raw }
    }

    /// The last component; nil for `/`.
    public var name: RemoteName? { components.last }

    /// The folder holding this path; `/` for `/`.
    public var parent: RemotePath { RemotePath(components: components.dropLast()) }

    public func appending(_ name: RemoteName) -> RemotePath {
        RemotePath(components: components + [name])
    }
}
