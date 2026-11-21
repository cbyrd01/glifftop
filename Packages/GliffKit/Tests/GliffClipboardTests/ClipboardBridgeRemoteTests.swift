import GliffProtocol
import Testing

@testable import GliffClipboard

@Suite struct ClipboardBridgeRemoteTests {
    private let text = ClipboardMimes.text

    private func file(_ path: String, _ size: Int) -> ClipboardFile {
        ClipboardFile(path: path, size: UInt64(size), isDirectory: false)
    }

    private func firstEvent(_ bridge: ClipboardBridge) async -> ClipboardBridgeEvent? {
        var events = bridge.events.makeAsyncIterator()
        return await events.next()
    }

    @Test func aRemoteOfferIsReported() async throws {
        let peer = RemotePeer()
        await peer.offer(serial: 5, mimeTypes: [text, ClipboardMimes.passwordHint])
        let offer = RemoteClipboardOffer(
            serial: 5, mimeTypes: [text, ClipboardMimes.passwordHint], isFirst: true)
        #expect(await firstEvent(peer.bridge) == .remoteOffer(offer))
        #expect(offer.isPassword && !offer.isEmpty)
    }

    /// The server reports the host's clipboard at connect: only that first offer is marked.
    @Test func onlyTheSessionsFirstOfferIsMarkedFirst() async throws {
        let peer = RemotePeer()
        await peer.offer(serial: 5, mimeTypes: [text])
        await peer.offer(serial: 6, mimeTypes: [text])
        var events = peer.bridge.events.makeAsyncIterator()
        #expect(await events.next() == .remoteOffer(.init(serial: 5, mimeTypes: [text], isFirst: true)))
        #expect(await events.next() == .remoteOffer(.init(serial: 6, mimeTypes: [text])))
    }

    @Test func anOfferOfOnlyTheHintIsEmpty() {
        #expect(RemoteClipboardOffer(serial: 1, mimeTypes: [ClipboardMimes.passwordHint]).isEmpty)
    }

    /// Files aren't shared: an offer's list is ignored, its types still paste.
    @Test func aRemoteOffersFilesAreIgnored() async throws {
        let peer = RemotePeer()
        await peer.offer(serial: 5, mimeTypes: [text], files: [file("a.txt", 1)])
        #expect(
            await firstEvent(peer.bridge)
                == .remoteOffer(.init(serial: 5, mimeTypes: [text], hasFiles: true, isFirst: true))
        )
    }

    /// A copy of files alone puts nothing on the Mac, but isn't a cleared clipboard either.
    @Test func aFilesOnlyRemoteOfferIsEmptyButHasFiles() async throws {
        let peer = RemotePeer()
        await peer.offer(serial: 5, files: [file("a.txt", 1)])
        let offer = RemoteClipboardOffer(serial: 5, mimeTypes: [], hasFiles: true, isFirst: true)
        #expect(await firstEvent(peer.bridge) == .remoteOffer(offer))
        #expect(offer.isEmpty)
    }

    @Test func fetchingText() async throws {
        let peer = RemotePeer(mimes: [text: Array("hello".utf8)])
        await peer.offer(serial: 5, mimeTypes: [text])
        let bytes = try await peer.bridge.fetch(text, serial: 5, progress: TransferProgress())
        #expect(bytes == Array("hello".utf8))
    }

    @Test func aReplacedOfferIsRefusedLocally() async throws {
        let peer = RemotePeer(mimes: [text: [1]])
        await peer.offer(serial: 5, mimeTypes: [text])
        await #expect(throws: TransferError.replaced) {
            try await peer.bridge.fetch(text, serial: 4, progress: TransferProgress())
        }
        #expect(peer.requests.isEmpty)
    }
}
