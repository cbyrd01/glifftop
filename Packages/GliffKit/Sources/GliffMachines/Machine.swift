public import Foundation
public import GliffClipboard
public import GliffSession
public import GliffTransport

/// How a machine connects: the screen, and for a virtual screen its text size and resolution;
/// Scale to Fit; whether a dropped link is tried again; its clipboard sharing (nil: as
/// Settings says); and the ports it forwards when connected.
public struct MachineOptions: Codable, Hashable, Sendable {
    public var screen: ScreenChoice
    public var textSize: TextSize
    public var resolution: VirtualResolution
    public var scaleToFit: Bool
    public var reconnects: Bool
    public var clipboard: ClipboardSharing?
    public var forwards: [SavedForward]

    public init(
        screen: ScreenChoice = .focused, textSize: TextSize = .mac,
        resolution: VirtualResolution = .automatic,
        scaleToFit: Bool = false, reconnects: Bool = true, clipboard: ClipboardSharing? = nil,
        forwards: [SavedForward] = []
    ) {
        (self.screen, self.textSize, self.resolution, self.scaleToFit, self.reconnects, self.clipboard) = (
            screen, textSize, resolution, scaleToFit, reconnects, clipboard
        )
        self.forwards = forwards
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
            reconnects: value(.reconnects, defaults.reconnects),
            clipboard: value(.clipboard, defaults.clipboard),
            forwards: SavedForward.once(value(.forwards, [Lossy<SavedForward>]()).compactMap(\.value)))
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

extension MachineOptions {
    /// The clipboard sharing in force for a window: its saved machine's (so every window to it
    /// follows a change made in any one), else the window's own before the machine is saved;
    /// nil in either follows Settings'.
    public static func clipboard(saved: Machine?, window: ClipboardSharing?, settings: ClipboardSharing)
        -> ClipboardSharing
    {
        (saved.map(\.options.clipboard) ?? window) ?? settings
    }

    /// These options, a window's, as a streamed session records them over its machine's
    /// `saved`: but for the screen when `keepsScreen` (a reconnect's try, or a tab's own
    /// screen: not the machine's to change) and the clipboard when `keepsClipboard` (the window
    /// chose none since it was last kept, and another window may have changed the machine's).
    /// The forwards are always the machine's: a window doesn't keep its own.
    public func recorded(over saved: MachineOptions, keepsScreen: Bool, keepsClipboard: Bool)
        -> MachineOptions
    {
        var options = self
        options.forwards = saved.forwards
        if keepsScreen { options.screen = saved.screen }
        if keepsClipboard { options.clipboard = saved.clipboard }
        return options
    }
}
