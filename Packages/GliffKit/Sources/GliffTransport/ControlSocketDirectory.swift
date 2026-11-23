#if os(macOS)
    import Foundation

    /// Where the masters' sockets live: a directory only this user can enter, short enough for a
    /// socket path. A socket there is named `<pid>-<n>`, so one left by an app that crashed is
    /// known by its pid.
    struct ControlSocketDirectory {
        /// `sockaddr_un.sun_path`'s size on macOS, its terminating NUL included.
        static let sunPathLimit = 104
        /// What ssh adds to a master's socket path while creating it (`.` and 16 random letters).
        static let sshSuffix = 17
        /// The longest socket name: a pid of up to 6 digits, `-`, a `UInt32` of up to 10.
        static let nameLimit = 17

        struct Refused: Error, Equatable {
            let reason: String
        }

        typealias Attributes = [FileAttributeKey: Any]

        let path: String

        /// `preferred` (the caches directory's `ssh/`) when it fits and can be made private, else
        /// `fallback` (`/tmp/glifftop-<uid>`). Each is created 0700 if missing; one that is a
        /// symbolic link, not a directory, or not this user's is refused.
        static func prepare(
            preferred: URL, fallback: URL, isMine: (Attributes) -> Bool = Self.isOwnedByThisUser
        ) throws(Refused) -> ControlSocketDirectory {
            do {
                return try make(preferred.path, isMine: isMine)
            } catch {
                return try make(fallback.path, isMine: isMine)
            }
        }

        /// The default: the caches directory, else `/tmp`.
        static func standard() throws(Refused) -> ControlSocketDirectory {
            let caches =
                FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
                ?? URL(filePath: NSTemporaryDirectory())
            return try prepare(
                preferred: caches.appending(path: "me.cbyrd.Glifftop/ssh"),
                fallback: URL(filePath: "/tmp/glifftop-\(getuid())"))
        }

        func socketPath(number: UInt32) -> String { path + "/\(getpid())-\(number)" }

        /// Removes the sockets of Glifftops no longer running, calling `ending` with each path
        /// first (its master may have outlived its app). Run at launch, before any master: a
        /// socket with this app's own pid is then an earlier Glifftop's. Anything that isn't a
        /// socket named `<pid>-<n>` is left alone.
        func removeStale(
            isRunning: (Int32) -> Bool = Self.isRunning,
            ending: @escaping @Sendable (String) async -> Void = { _ in }
        ) async {
            let files = FileManager.default
            let own = getpid()
            let stale = ((try? files.contentsOfDirectory(atPath: path)) ?? []).compactMap { name -> String? in
                let parts = name.split(separator: "-")
                let socket = path + "/" + name
                guard parts.count == 2, UInt32(parts[1]) != nil, let pid = Int32(parts[0]),
                    pid == own || !isRunning(pid),
                    (try? files.attributesOfItem(atPath: socket))?[.type] as? FileAttributeType == .typeSocket
                else { return nil }
                return socket
            }
            // Each master is ended before its socket goes, all at once.
            await withTaskGroup(of: Void.self) { group in
                for socket in stale {
                    group.addTask {
                        await ending(socket)
                        try? FileManager.default.removeItem(atPath: socket)
                    }
                }
            }
        }

        private static func make(_ path: String, isMine: (Attributes) -> Bool) throws(Refused) -> Self {
            guard path.utf8.count + 1 + nameLimit + sshSuffix < sunPathLimit else {
                throw Refused(reason: "too long")
            }
            let files = FileManager.default
            if !files.fileExists(atPath: path) {
                do {
                    try files.createDirectory(
                        atPath: path, withIntermediateDirectories: true,
                        attributes: [.posixPermissions: 0o700])
                } catch {
                    throw Refused(reason: "can't create")
                }
            }
            guard let attributes = try? files.attributesOfItem(atPath: path),
                attributes[.type] as? FileAttributeType == .typeDirectory
            else { throw Refused(reason: "not a directory") }
            guard isMine(attributes) else { throw Refused(reason: "not this user's") }
            do {
                try files.setAttributes([.posixPermissions: 0o700], ofItemAtPath: path)
            } catch {
                throw Refused(reason: "can't make private")
            }
            return Self(path: path)
        }

        static func isOwnedByThisUser(_ attributes: Attributes) -> Bool {
            (attributes[.ownerAccountID] as? NSNumber)?.uint32Value == getuid()
        }

        /// Whether a process with this pid exists (signal 0 checks without sending).
        static func isRunning(_ pid: Int32) -> Bool {
            kill(pid, 0) == 0 || errno == EPERM
        }
    }
#endif
