/// A monitor on the host, as Get Screens lists it. Never saved: monitors come and
/// go with the host's setup.
public struct RemoteScreen: Hashable, Sendable {
    /// The connector name gliff-server takes (`DP-3`); only `[A-Za-z0-9._:-]`, 1–64 characters.
    public var name: String
    /// Make and model, never the serial number.
    public var description: String
    /// The mode in pixels, as the monitor stands (a rotated one's sides swapped).
    public var width: Int
    public var height: Int
    public var scale: Double
    public var isFocused: Bool
    /// The monitor's top-left in the host's layout, in pixels; nil when the host didn't say.
    public var x: Int?
    public var y: Int?

    public init(
        name: String, description: String, width: Int, height: Int, scale: Double, isFocused: Bool,
        x: Int? = nil, y: Int? = nil
    ) {
        (self.name, self.description, self.width, self.height) = (name, description, width, height)
        (self.scale, self.isFocused, self.x, self.y) = (scale, isFocused, x, y)
    }
}

/// Why Get Screens has no list.
public enum ScreenListError: Error, Equatable, Sendable {
    /// ssh or the host refused; the same words as a failed connect.
    case failed(ConnectFailure)
    case timedOut
    case tooLarge
    case unreadable
    /// Whoever asked went away first.
    case cancelled

    /// Shown under the screen picker.
    public var message: String {
        switch self {
        case .failed(let failure): failure.message
        case .timedOut: "The host didn't answer in time."
        case .tooLarge: "The host's list of monitors was too large to read."
        case .unreadable: "The host's list of monitors couldn't be read."
        case .cancelled: "Listing the monitors was cancelled."
        }
    }
}
