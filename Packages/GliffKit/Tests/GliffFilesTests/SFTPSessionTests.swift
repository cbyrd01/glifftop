#if os(macOS)
    import Foundation
    import GliffSFTP
    import GliffTransport
    import Testing

    @testable import GliffFiles

    /// The session against the system's own `sftp-server`, over its stdin and stdout.
    @Suite struct SFTPSessionTests {
        static let server = URL(filePath: "/usr/libexec/sftp-server")

        /// Runs `body` on a session, closing it on every path so no sftp-server outlives the test.
        func withSession(_ body: (SFTPSession) async throws -> Void) async throws {
            let connection = try await ProcessTransport(executable: Self.server, arguments: []).connect()
            let session = try await SFTPSession.start(over: connection)
            do {
                try await body(session)
            } catch {
                await session.close()
                throw error
            }
            await session.close()
        }

        func temporaryFolder() throws -> URL {
            let folder = FileManager.default.temporaryDirectory.appending(path: "SFTPSessionTests-\(UUID())")
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            return folder
        }

        @Test func startReadsTheExtensions() async throws {
            try await withSession { session in
                #expect(session.extensions.posixRename)
                #expect(session.extensions.statvfs)
                #expect(session.extensions.fsync)
                #expect(session.extensions.limits)
                let limits = try await session.limits()
                #expect(limits.writeLength > 0)
            }
        }

        @Test func aFileRoundTrips() async throws {
            let folder = try temporaryFolder()
            defer { try? FileManager.default.removeItem(at: folder) }
            try await withSession { session in try await roundTrip(on: session, in: folder) }
        }

        func roundTrip(on session: SFTPSession, in folder: URL) async throws {
            let path = Array(folder.appending(path: "report.pdf").path(percentEncoded: false).utf8)
            let contents = (0..<70_000).map { UInt8($0 % 251) }

            let out = try await session.open(path, flags: [.write, .create, .exclusive])
            try await session.write(handle: out, offset: 0, data: Array(contents[..<32_768]))
            try await session.write(handle: out, offset: 32_768, data: Array(contents[32_768...]))
            try await session.fsync(handle: out, bytesWritten: UInt64(contents.count))
            try await session.close(handle: out)

            #expect(try await session.lstat(path).size == UInt64(contents.count))
            let back = try await session.open(path, flags: .read)
            var read: [UInt8] = []
            while let bytes = try await session.read(handle: back, offset: UInt64(read.count), length: 32_768)
            {
                read += bytes
            }
            try await session.close(handle: back)
            #expect(read == contents)

            await #expect(throws: FilesError.failure) {
                try await session.open(path, flags: [.write, .create, .exclusive])
            }
            try await session.remove(path)
            await #expect(throws: FilesError.noSuchFile) { try await session.lstat(path) }
            await session.close()
            await #expect(throws: FilesError.ended) { try await session.lstat(path) }
        }
    }
#endif
