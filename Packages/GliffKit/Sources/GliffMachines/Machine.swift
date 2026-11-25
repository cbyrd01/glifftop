public import Foundation
public import GliffClipboard
public import GliffMacros
public import GliffSession
public import GliffTransport

/// How a machine connects: the screen, and for a virtual screen its text size and resolution;
/// Scale to Fit; whether a dropped link is tried again; and its clipboard sharing (nil: as
/// Settings says).
public struct MachineOptions: Codable, Equatable, Sendable {
    public var screen: ScreenChoice
    public var textSize: TextSize
    public var resolution: VirtualResolution
    public var scaleToFit: Bool
    public var reconnects: Bool
    public var clipboard: ClipboardSharing?

    public init(
        screen: ScreenChoice = .focused, textSize: TextSize = .mac,
        resolution: VirtualResolution = .automatic,
        scaleToFit: Bool = false, reconnects: Bool = true, clipboard: ClipboardSharing? = nil
    ) {
        (self.screen, self.textSize, self.resolution, self.scaleToFit, self.reconnects, self.clipboard) = (
            screen, textSize, resolution, scaleToFit, reconnects, clipboard
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
            reconnects: value(.reconnects, defaults.reconnects),
            clipboard: value(.clipboard, defaults.clipboard))
    }
}

/// A saved machine: its name in the list, the destination ssh is given (host, user@host or
/// ssh://user@host:port), its options, whether it's a favourite, when it last connected, and
/// its macros, in run order (set by the machine sheet, Always Run, and a save that replaces a
/// machine with the same destination).
public struct Machine: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID
    public var name: String
    public var destination: String
    public var options: MachineOptions
    public var isFavorite: Bool
    public var lastConnected: Date?
    public var macros: [Macro]

    public init(
        id: UUID = UUID(), name: String, destination: String, options: MachineOptions = MachineOptions(),
        isFavorite: Bool = false, lastConnected: Date? = nil, macros: [Macro] = []
    ) {
        (self.id, self.name, self.destination, self.options, self.isFavorite, self.lastConnected) = (
            id, name, destination, options, isFavorite, lastConnected
        )
        self.macros = macros
    }

    private enum CodingKeys: String, CodingKey {
        case id, name, destination, options, isFavorite, lastConnected, macros
    }

    /// Every field as stored, and `macros` read lossily: missing or not a list is none, an
    /// entry that can't be read or repeats an id is dropped, and past `MacroLimits`' count or
    /// size the first that fit are kept.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let entries = (try? container.decode([Lossy<Macro>].self, forKey: .macros)) ?? []
        self.init(
            id: try container.decode(UUID.self, forKey: .id),
            name: try container.decode(String.self, forKey: .name),
            destination: try container.decode(String.self, forKey: .destination),
            options: try container.decode(MachineOptions.self, forKey: .options),
            isFavorite: try container.decode(Bool.self, forKey: .isFavorite),
            lastConnected: try container.decodeIfPresent(Date.self, forKey: .lastConnected),
            macros: Self.fitting(entries.compactMap(\.value)))
    }

    /// The first of `macros` that fit `MacroLimits`' count and total size, in order, each id
    /// once.
    static func fitting(_ macros: [Macro]) -> [Macro] {
        var kept: [Macro] = []
        var ids: Set<UUID> = []
        var bytes = 0
        for macro in macros where kept.count < MacroLimits.macrosPerMachine {
            let size = macro.script.utf8.count
            guard ids.insert(macro.id).inserted, bytes + size <= MacroLimits.machineScriptBytes else {
                continue
            }
            kept.append(macro)
            bytes += size
        }
        return kept
    }
}

/// A list entry that decodes to nil rather than failing the whole list.
struct Lossy<Value: Decodable>: Decodable {
    let value: Value?

    init(from decoder: any Decoder) throws {
        value = try? Value(from: decoder)
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
    public func recorded(over saved: MachineOptions, keepsScreen: Bool, keepsClipboard: Bool)
        -> MachineOptions
    {
        var options = self
        if keepsScreen { options.screen = saved.screen }
        if keepsClipboard { options.clipboard = saved.clipboard }
        return options
    }
}
