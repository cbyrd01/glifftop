import GliffSFTP
import GliffTransport

extension SFTPSession {
    /// What VERSION brought: the extensions, and the framer with any bytes after it.
    struct Opening: Sendable {
        let extensions: SFTPExtensions
        let framer: SFTPFramer
    }

    /// VERSION, or why it didn't come within `replyLimit`.
    static func opening(
        _ connection: any ByteConnection, clock: any Clock<Duration>
    ) async -> Result<Opening, FilesError> {
        await withTaskGroup(of: Result<Opening, FilesError>.self) { group in
            group.addTask { await readVersion(connection) }
            group.addTask {
                do { try await clock.sleep(for: replyLimit) } catch { return .failure(.cancelled) }
                return .failure(.timedOut)
            }
            let first = await group.next() ?? .failure(.ended)
            group.cancelAll()
            return first
        }
    }

    /// The first packet, which must be VERSION and come alone: no request has been sent.
    private static func readVersion(_ connection: any ByteConnection) async -> Result<Opening, FilesError> {
        var framer = SFTPFramer()
        do {
            for try await chunk in connection.incoming {
                let packets = try framer.feed(chunk)
                guard let first = packets.first else { continue }
                guard packets.count == 1, case .version(let extensions) = try SFTPReply.decode(first) else {
                    return .failure(.protocolBroken)
                }
                return .success(Opening(extensions: extensions, framer: framer))
            }
            try framer.finish()
            return .failure(.ended)
        } catch SFTPError.unsupportedVersion {
            return .failure(.unsupported)
        } catch {
            return .failure(FilesError(reading: error))
        }
    }
}
