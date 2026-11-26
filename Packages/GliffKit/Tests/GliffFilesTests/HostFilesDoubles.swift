import Foundation
import GliffTestSupport
import GliffTransport
import Synchronization

@testable import GliffFiles

/// A transport that hands out what `make` builds, one per connect, counting them.
final class PeerTransport: Transport {
    private let make: @Sendable (Int) async throws(TransportError) -> any ByteConnection
    private let count = Mutex(0)

    init(_ make: @escaping @Sendable () async throws(TransportError) -> any ByteConnection) {
        self.make = { _ async throws(TransportError) in try await make() }
    }

    /// `make` is given the connect's number, from 1.
    init(numbered make: @escaping @Sendable (Int) async throws(TransportError) -> any ByteConnection) {
        self.make = make
    }

    var connects: Int { count.withLock { $0 } }

    func connect() async throws(TransportError) -> any ByteConnection {
        let number = count.withLock { count in
            count += 1
            return count
        }
        return try await make(number)
    }
}

extension HostFiles {
    /// A host's files whose sftp channels `files` makes, with the folders command answering
    /// `home` unless `commands` is given.
    static func testing(
        files: PeerTransport, home: String = "/home/person", commands: PeerTransport? = nil,
        ledger: TemporaryLedger = TemporaryLedger(store: MemoryLedgerStore()),
        activity: RecordingActivity = RecordingActivity()
    ) -> HostFiles {
        HostFiles(
            host: "omarchy", channels: .testing(files: files, home: home, commands: commands),
            ledger: ledger, activity: activity)
    }
}

extension RemotePath {
    static let downloads = RemotePath(absolute: Array("/home/person/Downloads".utf8)) ?? .root
}

extension TransferProgress {
    /// Progress with a try begun on `plan`.
    static func begun<Source, Destination>(_ plan: TransferPlan<Source, Destination>) -> TransferProgress {
        let progress = TransferProgress()
        progress.begin(plan)
        return progress
    }
}

/// Whether `batch` reaches an end within `eventually`'s bound.
func ends(_ batch: TransferBatch) async -> Bool {
    await eventually { ![.queued, .running].contains(batch.progress.counts.state) }
}

/// A connection the test can cut, as a lost link does: `incoming` fails as the shared
/// connection lost, and the connection under it is closed. Past `stallAfter` bytes written, a
/// write waits for the cut, as a write into a dead link does.
final class SeverableConnection: ByteConnection {
    let incoming: AsyncThrowingStream<[UInt8], any Error>
    private let continuation: AsyncThrowingStream<[UInt8], any Error>.Continuation
    private let inner: any ByteConnection
    private let relay = Mutex<Task<Void, Never>?>(nil)
    private let stallAfter: Int
    private let written = Mutex(0)
    private let severed: AsyncStream<Void>
    private let severing: AsyncStream<Void>.Continuation

    init(_ inner: any ByteConnection, stallAfter: Int = .max) {
        (self.inner, self.stallAfter) = (inner, stallAfter)
        (severed, severing) = AsyncStream.makeStream()
        (incoming, continuation) = AsyncThrowingStream.makeStream()
        let continuation = continuation
        relay.withLock {
            $0 = Task {
                do {
                    for try await chunk in inner.incoming { continuation.yield(chunk) }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
        }
    }

    func write(_ bytes: [UInt8]) async throws(TransportError) {
        let total = written.withLock { written in
            written += bytes.count
            return written
        }
        if total > stallAfter {
            for await _ in severed {}
            throw .exited(status: 255, failure: .sharedConnectionLost)
        }
        try await inner.write(bytes)
    }

    func close() async {
        relay.withLock { $0 }?.cancel()
        continuation.finish()
        await inner.close()
    }

    func sever() async {
        severing.finish()
        relay.withLock { $0 }?.cancel()
        continuation.finish(throwing: TransportError.exited(status: 255, failure: .sharedConnectionLost))
        await inner.close()
    }
}

/// Counts the activities begun and ended.
final class RecordingActivity: TransferActivity {
    private let counts = Mutex((begun: 0, ended: 0))

    var held: Bool { counts.withLock { $0.begun > $0.ended } }
    var begun: Int { counts.withLock { $0.begun } }

    func begin() -> any NSObjectProtocol {
        counts.withLock { $0.begun += 1 }
        return NSObject()
    }

    func end(_ token: any NSObjectProtocol) { counts.withLock { $0.ended += 1 } }
}

extension FilesChannels {
    /// The sftp channel from `files`; the folders command answers `home` as HOME and its
    /// Downloads, counted in `commands`.
    static func testing(files: PeerTransport, home: String, commands: PeerTransport? = nil) -> Self {
        let command = commands ?? .folders(home: home)
        return FilesChannels(files: { _ in files }, command: { _, _ in command })
    }
}

extension PeerTransport {
    /// The folders command's channel, answering `home` as HOME and as its Downloads.
    static func folders(home: String) -> PeerTransport {
        let output = Array("HOME\t\(home)\0HOME_DOWNLOADS\t\(home)\0".utf8)
        return PeerTransport {
            let peer = ScriptedSFTPPeer(version: nil)
            peer.send(output)
            peer.end()
            return peer
        }
    }
}
