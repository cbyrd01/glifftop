/// The host's own folders, from one shell command on a channel of its own.
public struct HostFolders: Equatable, Sendable {
    public var home: RemotePath
    /// `xdg-user-dir DOWNLOAD` when set, else `$HOME/Downloads`, else `$HOME`.
    public var downloads: RemotePath
    public var desktop: RemotePath?
    public var documents: RemotePath?
}

/// Asks the host for its folders: `script`, run by `sh -c`, prints one `KEY<TAB>path` record
/// each, ended by NUL, so a path holding a newline is kept whole.
///
/// - HOME comes first; then HOME_DOWNLOADS (`$HOME/Downloads`) when that is a directory, then
///   `xdg-user-dir`'s answer for DOWNLOAD, DESKTOP and DOCUMENTS when it is a directory.
/// - `parse` reads whole records within 16 KiB; a path must be absolute. An
///   `xdg-user-dir` answer equal to HOME is its answer for a folder not set, so it is dropped;
///   Downloads then falls back to HOME_DOWNLOADS, else HOME. Each path is then checked by its
///   caller (STAT, a directory) before it is used.
public enum HostFoldersCommand {
    /// One line, with no single quote or `!`, for `sh -c '…'` under any login shell.
    public static let script =
        #"printf "HOME\t%s\0" "$HOME"; [ -d "$HOME/Downloads" ] && printf "HOME_DOWNLOADS\t%s\0" "$HOME/Downloads"; "#
        + #"for k in DOWNLOAD DESKTOP DOCUMENTS; do d=$(xdg-user-dir $k 2>/dev/null); "#
        + #"[ -d "$d" ] && printf "%s\t%s\0" "$k" "$d"; done; exit 0"#

    /// The line the host's login shell runs.
    public static var remoteCommand: String { "sh -c '\(script)'" }

    public static let maxOutput = 16 * 1024

    /// The folders the output names; nil without an absolute HOME.
    public static func parse(_ output: [UInt8]) -> HostFolders? {
        var found: [String: RemotePath] = [:]
        // Only whole records within the cap count.
        let lines = output.prefix(maxOutput).split(separator: 0, omittingEmptySubsequences: false)
            .dropLast()
        for line in lines {
            guard let tab = line.firstIndex(of: 0x09),
                let key = String(validating: line[..<tab], as: UTF8.self),
                let path = RemotePath(absolute: Array(line[(tab + 1)...]))
            else { continue }
            if found[key] == nil { found[key] = path }
        }
        guard let home = found["HOME"] else { return nil }
        let xdg = { (key: String) in found[key].flatMap { $0 == home ? nil : $0 } }
        return HostFolders(
            home: home, downloads: xdg("DOWNLOAD") ?? found["HOME_DOWNLOADS"] ?? home,
            desktop: xdg("DESKTOP"), documents: xdg("DOCUMENTS"))
    }
}
