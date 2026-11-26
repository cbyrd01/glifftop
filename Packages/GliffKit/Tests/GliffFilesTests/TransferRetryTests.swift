import Foundation
import GliffSFTP
import GliffTestSupport
import GliffTransport
import Synchronization
import Testing

@testable import GliffFiles

/// Tries that fail, are tried again, or are cancelled before the channel opens.
@Suite struct TransferRetryTests {
    let source: TemporaryFolder

    init() throws { source = try TemporaryFolder() }

    /// A try that fails before it begins finishes nothing: the next starts where the first
    /// stopped.
    @Test func aTryThatFailsBeforeItBeginsSkipsNothing() async throws {
        defer { source.remove() }
        let names = ["a.bin", "b.bin", "c.bin"]
        let urls = try names.map { name in
            let url = try source.file(name)
            try Data(count: 100).write(to: url)
            return url
        }
        let last = UploadPeer()
        let files = HostFiles.testing(
            files: PeerTransport(numbered: { number async throws(TransportError) in
                switch number {
                case 1: return UploadPeer(refusing: "b.bin").connection
                case 2: throw .exited(status: 255, failure: .sharedConnectionLost)
                default: return last.connection
                }
            }))
        let batch = await files.enqueue(.upload(urls, to: .downloads, clash: .keepBoth), asker: nil)
        #expect(await ends(batch))
        #expect(batch.progress.counts.state == .failed(.permissionDenied))
        await files.retry(batch.id, asker: nil)
        #expect(await eventually { batch.progress.counts.state == .failed(.connectionLost) })
        await files.retry(batch.id, asker: nil)
        #expect(await eventually { batch.progress.counts.state == .finished })
        let opened = last.connection.requests.filter { $0.type == .open }.map(UploadPeer.path)
        #expect(opened.count == 2 && opened[0].contains(".b.bin.") && opened[1].contains(".c.bin."))
    }

    /// A batch cancelled while its channel opens (a sign-in question up, a slow link) stops at
    /// once and lets the next run.
    @Test func cancelWhileTheChannelOpensStopsAtOnce() async throws {
        defer { source.remove() }
        let (gate, open) = AsyncStream<Void>.makeStream()
        defer { open.finish() }
        let files = HostFiles.testing(
            files: PeerTransport { () async throws(TransportError) in
                for await _ in gate {}
                throw .cancelled
            })
        let url = try source.file("report.pdf")
        try Data(count: 100).write(to: url)
        let batch = await files.enqueue(.upload([url], to: .downloads, clash: .keepBoth), asker: nil)
        #expect(await eventually { batch.progress.counts.state == .running })
        await files.cancel(batch.id)
        #expect(await ends(batch))
        #expect(batch.progress.counts.state == .cancelled)
        #expect(await !files.hasWork)
    }
}
