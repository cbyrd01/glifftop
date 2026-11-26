/// What a session shows: the monitor that has focus when it starts, a monitor by
/// name, or a virtual screen sized to the window. gliff-server picks its output only at start,
/// from these arguments, so changing the choice means a new session.
public enum ScreenChoice: Hashable, Sendable {
    case focused
    case named(String)
    case virtual

    public var serverArguments: [String] {
        switch self {
        case .focused: ["--output", "auto"]
        case .named(let name): ["--output", name]
        case .virtual: ["--headless"]
        }
    }
}

/// Stored with a machine. A name read back becomes a server argument, so it must be one Get
/// Screens could offer (`ScreenListParser.isMonitorName`); else decoding fails. Encoding is
/// Swift's own, which `Stored` mirrors case for case.
extension ScreenChoice: Codable {
    private enum Stored: Codable {
        case focused
        case named(String)
        case virtual
    }

    public init(from decoder: any Decoder) throws {
        switch try Stored(from: decoder) {
        case .focused: self = .focused
        case .virtual: self = .virtual
        case .named(let name):
            guard ScreenListParser.isMonitorName(name) else {
                throw DecodingError.dataCorrupted(
                    .init(codingPath: decoder.codingPath, debugDescription: "screen name"))
            }
            self = .named(name)
        }
    }
}
