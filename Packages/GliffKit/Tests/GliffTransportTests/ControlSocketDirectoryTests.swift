#if os(macOS)
    import Foundation
    import Synchronization
    import Testing

    @testable import GliffTransport

    @Suite final class ControlSocketDirectoryTests {
        /// Under `/tmp`, so the path stays short whatever `TMPDIR` is.
        let root = URL(filePath: "/tmp/csd-\(UUID().uuidString.prefix(8))")

        init() throws {
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        }

        deinit { try? FileManager.default.removeItem(at: root) }

        /// A Unix-domain socket file at `path`, as a master leaves one.
        func makeSocket(_ path: String) throws {
            let fd = socket(AF_UNIX, SOCK_STREAM, 0)
            defer { close(fd) }
            var address = sockaddr_un()
            address.sun_family = sa_family_t(AF_UNIX)
            withUnsafeMutableBytes(of: &address.sun_path) { buffer in
                for (index, byte) in path.utf8.enumerated() { buffer[index] = byte }
            }
            let result = withUnsafePointer(to: &address) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
                }
            }
            try #require(result == 0)
        }

        func mode(_ url: URL) throws -> Int {
            try (FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? Int) ?? -1
        }

        @Test func thePreferredDirectoryIsUsed() throws {
            let preferred = root.appending(path: "ssh")
            let directory = try ControlSocketDirectory.prepare(
                preferred: preferred, fallback: root.appending(path: "f"))
            #expect(directory.path == preferred.path)
            #expect(directory.socketPath(number: 3) == preferred.path + "/\(getpid())-3")
        }

        @Test func aTooLongDirectoryFallsBack() throws {
            let padding = String(repeating: "x", count: 90 - root.path.utf8.count - 1)
            let preferred = root.appending(path: padding)
            #expect(preferred.path.utf8.count >= 90)
            let fallback = root.appending(path: "f")
            let directory = try ControlSocketDirectory.prepare(preferred: preferred, fallback: fallback)
            #expect(directory.path == fallback.path)
        }

        @Test func theCachesDirectoryFitsALongUserName() {
            let caches = URL(filePath: "/Users/\(String(repeating: "u", count: 24))/Library/Caches")
            let preferred = ControlSocketDirectory.preferred(caches: caches)
            #expect(preferred.path.hasPrefix(caches.path + "/"))
            #expect(ControlSocketDirectory.fits(preferred.path))
        }

        @Test func theDirectoryIsPrivate() throws {
            let preferred = root.appending(path: "ssh")
            try FileManager.default.createDirectory(
                at: preferred, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o755])
            _ = try ControlSocketDirectory.prepare(preferred: preferred, fallback: root.appending(path: "f"))
            #expect(try mode(preferred) == 0o700)
        }

        @Test func aDirectoryOwnedByAnotherUserIsRefused() throws {
            #expect(throws: ControlSocketDirectory.Refused.self) {
                try ControlSocketDirectory.prepare(
                    preferred: root.appending(path: "a"), fallback: root.appending(path: "b"),
                    isMine: { _ in false })
            }
        }

        @Test func aSymbolicLinkIsRefused() throws {
            let elsewhere = root.appending(path: "elsewhere")
            try FileManager.default.createDirectory(at: elsewhere, withIntermediateDirectories: false)
            let link = root.appending(path: "link")
            try FileManager.default.createSymbolicLink(at: link, withDestinationURL: elsewhere)
            #expect(throws: ControlSocketDirectory.Refused.self) {
                try ControlSocketDirectory.prepare(preferred: link, fallback: link)
            }
        }

        /// At launch no master of this app exists yet, so a socket with its pid is an earlier
        /// Glifftop's that had the same pid.
        @Test func staleSocketsAreRemoved() async throws {
            let directory = try ControlSocketDirectory.prepare(
                preferred: root.appending(path: "ssh"), fallback: root.appending(path: "f"))
            let path = { (name: String) in directory.path + "/" + name }
            for name in ["111-1", "\(getpid())-1", "222-1"] { try makeSocket(path(name)) }
            FileManager.default.createFile(atPath: path("333-1"), contents: Data())
            try FileManager.default.createDirectory(atPath: path("444-1"), withIntermediateDirectories: false)
            let ended = Mutex<[String]>([])
            await directory.removeStale(
                isRunning: { $0 == 222 }, ending: { path in ended.withLock { $0.append(path) } })
            let left = try FileManager.default.contentsOfDirectory(atPath: directory.path).sorted()
            #expect(left == ["222-1", "333-1", "444-1"])
            #expect(ended.withLock { $0.sorted() } == [path("111-1"), path("\(getpid())-1")].sorted())
        }

        /// A bridge's socket (`<pid>-<n>-a`) is never taken for a master: a live app's stays, and
        /// a gone app's (or an earlier Glifftop's with this pid) is removed without ending anything.
        @Test func removeStaleKeepsALiveBridgeSocket() async throws {
            let directory = try ControlSocketDirectory.prepare(
                preferred: root.appending(path: "ssh"), fallback: root.appending(path: "f"))
            #expect(
                ControlSocketDirectory.bridgePath(forMaster: directory.socketPath(number: 3))
                    == directory.path + "/\(getpid())-3-a")
            try makeSocket(directory.path + "/222-1-a")
            let ended = Mutex<[String]>([])
            await directory.removeStale(
                isRunning: { $0 == 222 }, ending: { p in ended.withLock { $0.append(p) } })
            #expect(try FileManager.default.contentsOfDirectory(atPath: directory.path) == ["222-1-a"])
            #expect(ended.withLock { $0.isEmpty })
        }

        @Test func removeStaleRemovesADeadAppsBridgeSocket() async throws {
            let directory = try ControlSocketDirectory.prepare(
                preferred: root.appending(path: "ssh"), fallback: root.appending(path: "f"))
            for name in ["111-1-a", "\(getpid())-2-a"] { try makeSocket(directory.path + "/" + name) }
            FileManager.default.createFile(atPath: directory.path + "/111-1-b", contents: Data())
            let ended = Mutex<[String]>([])
            await directory.removeStale(
                isRunning: { _ in false }, ending: { p in ended.withLock { $0.append(p) } })
            #expect(try FileManager.default.contentsOfDirectory(atPath: directory.path) == ["111-1-b"])
            #expect(ended.withLock { $0.isEmpty })
        }

        @Test func staleMastersEndTogether() async throws {
            let directory = try ControlSocketDirectory.prepare(
                preferred: root.appending(path: "ssh"), fallback: root.appending(path: "f"))
            for number in 1...3 { try makeSocket(directory.path + "/111-\(number)") }
            // Each ending waits for all three to begin: one at a time, the first would give up.
            let begun = Mutex(0)
            let metAll = Mutex(0)
            let ending: @Sendable (String) async -> Void = { _ in
                begun.withLock { $0 += 1 }
                let deadline = ContinuousClock.now + .seconds(5)
                while begun.withLock({ $0 }) < 3, ContinuousClock.now < deadline {
                    try? await Task.sleep(for: .milliseconds(10))
                }
                if begun.withLock({ $0 }) == 3 { metAll.withLock { $0 += 1 } }
            }
            await directory.removeStale(isRunning: { _ in false }, ending: ending)
            #expect(metAll.withLock { $0 } == 3)
            #expect(try FileManager.default.contentsOfDirectory(atPath: directory.path).isEmpty)
        }

        /// The app's socket numbering: one for the whole app, prepared once it works.
        @Test func socketsAreNumberedInTurnAndAFailedPrepareIsTriedAgain() async throws {
            let tries = Mutex(0)
            let preferred = root.appending(path: "ssh")
            let sockets = SystemSSHSockets {
                let first = tries.withLock { tries in
                    defer { tries += 1 }
                    return tries == 0
                }
                if first { return nil }
                return try? ControlSocketDirectory.prepare(preferred: preferred, fallback: preferred)
            }
            await #expect(throws: TransportError.self) { try await sockets.next() }
            let pid = getpid()
            #expect(try await sockets.next() == preferred.path + "/\(pid)-1")
            #expect(try await sockets.next() == preferred.path + "/\(pid)-2")
            #expect(tries.withLock { $0 } == 2)
        }

        /// At launch: the directory is prepared (the masters of Glifftops no longer running are
        /// ended) before any connection, and once only.
        @Test func preparingAtLaunchIsDoneOnce() async throws {
            let tries = Mutex(0)
            let preferred = root.appending(path: "ssh")
            let sockets = SystemSSHSockets {
                tries.withLock { $0 += 1 }
                return try? ControlSocketDirectory.prepare(preferred: preferred, fallback: preferred)
            }
            await sockets.prepare()
            #expect(tries.withLock { $0 } == 1)
            #expect(try await sockets.next() == preferred.path + "/\(getpid())-1")
            #expect(tries.withLock { $0 } == 1)
        }
    }
#endif
