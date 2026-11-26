import GliffSFTP
import GliffTestSupport
import Synchronization
import Testing

@testable import GliffFiles

/// Listings against a scripted host: OPENDIR answers a handle, each READDIR the next NAME
/// batch, then EOF; STAT answers a directory; CLOSE answers `closeCode` (OK by default).
@Suite struct RemoteListingTests {
    typealias B = SFTPBytes
    typealias Peer = ScriptedSFTPPeer

    static let home = RemotePath(absolute: Array("/home/person".utf8))!

    /// A NAME entry: the name, an empty longname, and attributes with the permissions `mode`.
    static func entry(_ name: [UInt8], mode: UInt32 = 0o100644) -> [UInt8] {
        B.string(name) + B.string("") + B.attributeFields(mode: mode)
    }

    /// With `brokenStat`, STAT is answered under another id, which ends the session.
    static func peer(batches: [[[UInt8]]], closeCode: UInt32 = 0, brokenStat: Bool = false)
        -> ScriptedSFTPPeer
    {
        let next = Mutex(0)
        return ScriptedSFTPPeer { request in
            switch request.type {
            case .opendir: return B.handle(request.id)
            case .readdir:
                let index = next.withLock { index in
                    defer { index += 1 }
                    return index
                }
                guard index < batches.count else { return B.status(request.id, 1) }
                return B.name(request.id, batches[index])
            case .stat: return B.attributes(brokenStat ? request.id + 1000 : request.id, mode: 0o40755)
            case .close: return B.status(request.id, closeCode)
            default: return B.status(request.id, 0)
            }
        }
    }

    func list(_ batches: [[[UInt8]]], closeCode: UInt32 = 0) async throws -> (
        RemoteListing, ScriptedSFTPPeer
    ) {
        let peer = Self.peer(batches: batches, closeCode: closeCode)
        let session = try await SFTPSession.start(over: peer)
        let listing = try await RemoteListing.read(Self.home, on: session)
        return (listing, peer)
    }

    @Test func dotAndDotDotAreSkipped() async throws {
        let (listing, peer) = try await list([
            [Self.entry([0x2E]), Self.entry([0x2E, 0x2E]), Self.entry(Array("a".utf8))]
        ])
        #expect(listing.entries.map(\.name.raw) == [Array("a".utf8)])
        #expect(listing.skippedNames == 0)
        #expect(peer.requests.contains { $0.type == .close })
    }

    @Test func aNameWithSlashIsSkippedAndCounted() async throws {
        let (listing, _) = try await list([
            [Self.entry(Array("a/b".utf8)), Self.entry([]), Self.entry(Array("ok".utf8))]
        ])
        #expect(listing.entries.count == 1)
        #expect(listing.skippedNames == 2)
    }

    @Test func aNameOver255BytesIsSkipped() async throws {
        let (listing, _) = try await list([[Self.entry([UInt8](repeating: 0x61, count: 256))]])
        #expect(listing.entries.isEmpty)
        #expect(listing.skippedNames == 1)
    }

    /// Hidden names are kept and marked, for a view to show or not.
    @Test func hiddenNamesAreKeptAndMarked() async throws {
        let (listing, _) = try await list([
            [Self.entry(Array(".config".utf8)), Self.entry(Array("notes".utf8))]
        ])
        #expect(listing.entries.map(\.name.isHidden) == [true, false])
    }

    @Test func kindsComeFromThePermissions() async throws {
        let (listing, _) = try await list([
            [
                Self.entry(Array("dir".utf8), mode: 0o40755), Self.entry(Array("fifo".utf8), mode: 0o10644),
            ]
        ])
        #expect(listing.entries.map(\.kind) == [.directory, .fifo])
    }

    /// 250-byte names, 900 to a batch: 16 MiB of names is 67,108 of them.
    @Test func aListingStopsAtSixteenMiBOfNames() async throws {
        let batches = (0..<80).map { batch in
            (0..<900).map { index in
                Self.entry(
                    Array("\(batch)-\(index)-".utf8)
                        + [UInt8](repeating: 0x61, count: 250 - "\(batch)-\(index)-".utf8.count))
            }
        }
        let (listing, peer) = try await list(batches)
        #expect(listing.truncated)
        #expect(listing.entries.count == (16 << 20) / 250)
        #expect(peer.requests.filter { $0.type == .readdir }.count < 80)
        #expect(peer.requests.contains { $0.type == .close })
    }

    /// Items the listing doesn't keep (hidden, `.`, `..`, unusable) still count toward its
    /// limits, so a host that never ends a folder can't keep it reading.
    @Test func skippedItemsCountTowardTheLimit() async throws {
        let batches = (0..<101).map { batch in (0..<1000).map { Self.entry(Array("a/\(batch)-\($0)".utf8)) } }
        let (listing, peer) = try await list(batches)
        #expect(listing.truncated)
        #expect(listing.entries.isEmpty)
        #expect(listing.skippedNames == RemoteListing.maxEntries)
        #expect(peer.requests.filter { $0.type == .readdir }.count == 101)
    }

    /// `.` and `..`, which every folder lists, don't count toward the item limit.
    @Test func aFolderOfExactlyTheLimitIsWhole() async throws {
        let names = (0..<100).map { batch in (0..<1000).map { Self.entry(Array("\(batch)-\($0)".utf8)) } }
        let (listing, _) = try await list([[Self.entry([0x2E]), Self.entry([0x2E, 0x2E])]] + names)
        #expect(!listing.truncated)
        #expect(listing.entries.count == RemoteListing.maxEntries)
    }

    /// A lookup that ends the session says so; a lookup the host refuses leaves the target unknown.
    @Test func aSessionEndingDuringLookupsIsReported() async throws {
        let peer = Self.peer(batches: [[Self.entry(Array("link".utf8), mode: 0o120777)]], brokenStat: true)
        let session = try await SFTPSession.start(over: peer)
        var listing = try await RemoteListing.read(Self.home, on: session)
        await #expect(throws: FilesError.protocolBroken) { try await listing.lookUpLinks(on: session) }
    }

    @Test func aRepeatedNameIsSkippedAndCounted() async throws {
        let (listing, _) = try await list([
            [Self.entry(Array("a".utf8)), Self.entry(Array("b".utf8))], [Self.entry(Array("a".utf8))],
        ])
        #expect(listing.entries.map(\.name.shown) == ["a", "b"])
        #expect(listing.skippedNames == 1)
    }

    /// A folder read to its end is kept though the host refuses to close it.
    @Test func aFailedCloseKeepsTheListing() async throws {
        let (listing, peer) = try await list([[Self.entry(Array("a".utf8))]], closeCode: 4)
        #expect(listing.entries.count == 1)
        #expect(peer.requests.contains { $0.type == .close })
    }

    /// Reading sends no STAT: a link into a hung mount can't hold the listing up.
    @Test func linkKindsAreLookedUpForAtMost256() async throws {
        let links = (0..<300).map { Self.entry(Array("link\($0)".utf8), mode: 0o120777) }
        let peer = Self.peer(batches: [links])
        let session = try await SFTPSession.start(over: peer)
        var listing = try await RemoteListing.read(Self.home, on: session)
        #expect(!peer.requests.contains { $0.type == .stat })
        #expect(listing.entries.allSatisfy { $0.linkTarget == nil })
        try await listing.lookUpLinks(on: session)
        #expect(peer.requests.filter { $0.type == .stat }.count == 256)
        #expect(listing.entries.filter { $0.linkTarget == .directory }.count == 256)
        #expect(listing.entries.allSatisfy { $0.kind == .link })
    }
}
