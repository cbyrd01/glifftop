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
