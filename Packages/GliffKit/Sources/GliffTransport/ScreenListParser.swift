import Foundation
import GliffProtocol

/// Reads `hyprctl -j monitors` from the host, as untrusted input: a JSON array of
/// monitors. A monitor's position that isn't a whole number within ±1,048,576 reads as none,
/// the monitor kept. A monitor whose name gliff-server couldn't take, with a field missing or
/// of the wrong type, or with an impossible size is left out; anything that isn't such an
/// array is unreadable. Hyprland's `description` and `serial` are never read: they carry the serial
/// number.
public enum ScreenListParser {
    /// Far more than any host's list; more is refused unread.
    public static let maxBytes = 1 << 20

    public static func screens(from bytes: [UInt8]) throws(ScreenListError) -> [RemoteScreen] {
        guard bytes.count <= maxBytes else { throw .tooLarge }
        // JSONDecoder refuses nesting deeper than its limit, so a hostile list can't recurse far.
        guard let entries = try? JSONDecoder().decode([Entry].self, from: Data(bytes)) else {
            throw .unreadable
        }
        // A repeated name couldn't be told apart when chosen: the first is kept.
        var seen = Set<String>()
        return entries.compactMap { $0.monitor?.screen }.filter { seen.insert($0.name).inserted }
    }

    private static let nameCharacters = Set(
        "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789._:-".unicodeScalars)
    private static let sides = 1...16384

    private static let scales = 0.25...10.0
    private static let positions = -1_048_576...1_048_576

    /// gliff-server takes the name after `--output`: a leading dash would read as an option,
    /// and `auto` means the focused monitor. Also what a monitor name the server sends must be
    /// to be shown.
    public static func isValidName(_ name: String) -> Bool {
        (1...64).contains(name.unicodeScalars.count)
            && name.unicodeScalars.allSatisfy(nameCharacters.contains) && !name.hasPrefix("-")
            && name != "auto"
    }

    /// A name a monitor of the host could have: one gliff-server takes, and no session's
    /// virtual screen.
    public static func isMonitorName(_ name: String) -> Bool {
        isValidName(name) && !OutputName.isVirtualScreen(name)
    }

    /// One array element: a monitor, or nil when it isn't one that can be shown.
    private struct Entry: Decodable {
        let monitor: Monitor?
        init(from decoder: any Decoder) { monitor = try? Monitor(from: decoder) }
    }

    private struct Monitor: Decodable {
        let name, make, model: String
        let width, height: Int
        let scale: Double
        let transform: Int?
        let focused, disabled: Bool?
        let x, y: Position?

        /// A virtual screen, this session's or another's, isn't offered: it goes when its
        /// session ends.
        var screen: RemoteScreen? {
            guard disabled != true, isMonitorName(name),
                sides.contains(width), sides.contains(height),
                scales.contains(scale)
            else { return nil }
            // Odd transforms turn the monitor a quarter: its sides swap.
            let turned = (transform ?? 0) % 2 != 0
            // As other remote text is shown: no control or format characters, a length limit
            // on the whole.
            let parts = [make, model].map {
                SSHErrorClassifier.displayable($0).trimmingCharacters(in: .whitespaces)
            }
            let text = SSHErrorClassifier.displayable(parts.filter { !$0.isEmpty }.joined(separator: " "))
            return RemoteScreen(
                name: name, description: text,
                width: turned ? height : width, height: turned ? width : height, scale: scale,
                isFocused: focused == true, x: x?.value, y: y?.value)
        }
    }

    /// A position, or none when it isn't a whole number in range: the monitor is still listed.
    private struct Position: Decodable {
        let value: Int?
        init(from decoder: any Decoder) {
            value = (try? decoder.singleValueContainer().decode(Int.self)).flatMap {
                positions.contains($0) ? $0 : nil
            }
        }
    }
}
