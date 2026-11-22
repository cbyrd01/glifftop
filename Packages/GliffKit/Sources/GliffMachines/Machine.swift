public import Foundation
public import GliffSession
public import GliffTransport

/// How a machine connects: the screen, and for a virtual screen its text size and resolution;
/// Scale to Fit; and whether a dropped link is tried again.
public struct MachineOptions: Codable, Equatable, Sendable {
    public var screen: ScreenChoice
    public var textSize: TextSize
    public var resolution: VirtualResolution
    public var scaleToFit: Bool
    public var reconnects: Bool

    public init(
        screen: ScreenChoice = .focused, textSize: TextSize = .mac,
        resolution: VirtualResolution = .automatic,
        scaleToFit: Bool = false, reconnects: Bool = true
    ) {
        (self.screen, self.textSize, self.resolution, self.scaleToFit, self.reconnects) = (
            screen, textSize, resolution, scaleToFit, reconnects
        )
    }

    /// An option missing or unreadable (stored by another version) takes its default.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let defaults = MachineOptions()
        func value<T: Decodable>(_ key: CodingKeys, _ fallback: T) -> T {
            (try? container.decodeIfPresent(T.self, forKey: key)) ?? fallback
        }
        self.init(
            screen: value(.screen, defaults.screen), textSize: value(.textSize, defaults.textSize),
            resolution: value(.resolution, defaults.resolution),
            scaleToFit: value(.scaleToFit, defaults.scaleToFit),
            reconnects: value(.reconnects, defaults.reconnects))
    }
}

/// A saved machine: its name in the list, the destination ssh is given (host, user@host or
/// ssh://user@host:port), its options, whether it's a favourite, and when it last connected.
public struct Machine: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID
    public var name: String
    public var destination: String
    public var options: MachineOptions
    public var isFavorite: Bool
    public var lastConnected: Date?

    public init(
        id: UUID = UUID(), name: String, destination: String, options: MachineOptions = MachineOptions(),
        isFavorite: Bool = false, lastConnected: Date? = nil
    ) {
        (self.id, self.name, self.destination, self.options, self.isFavorite, self.lastConnected) = (
            id, name, destination, options, isFavorite, lastConnected
        )
    }
}
