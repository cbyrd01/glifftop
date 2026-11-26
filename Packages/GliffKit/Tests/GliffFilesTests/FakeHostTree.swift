import Foundation
import GliffSFTP
import GliffTestSupport
import Synchronization

@testable import GliffFiles

/// A host's tree for a scripted peer, by absolute path: each item's permissions (nil: none
/// sent) and size, and for a link the path it leads to. LSTAT and FSTAT, REALPATH (a missing item or
/// target: no such file), OPENDIR, READDIR (up to 1,000 names a batch), OPEN and READ of a
/// file's contents (at most `readCap` bytes a reply), `limits` (none) and CLOSE are answered
/// from it; anything else gets STATUS OK, which ends a session expecting a value.
struct FakeHostTree: Sendable {
    struct Item: Sendable {
        var mode: UInt32?
        var size: UInt64 = 0
        var target: String? = nil
        /// A file's bytes, for OPEN and READ.
        var contents: [UInt8]? = nil

        /// A file with `contents`, its size theirs.
        static func file(_ contents: [UInt8], mode: UInt32 = 0o100644) -> Item {
            Item(mode: mode, size: UInt64(contents.count), contents: contents)
        }
    }

    /// The most bytes one READ answers, so a test can make reads short.
    var readCap = Int.max

    var items: [String: Item] = [:]

    subscript(path: String) -> Item? {
        get { items[path] }
        set { items[path] = newValue }
    }

    /// Each folder's items' paths, sorted.
    var children: [String: [String]] {
        Dictionary(grouping: items.keys.filter { $0 != "/" }) { ($0 as NSString).deletingLastPathComponent }
            .mapValues { $0.sorted() }
    }

    /// The attribute fields: the size, and the permissions when there are any.
    static func fields(_ item: Item) -> [UInt8] {
        var writer = SFTPWriter()
        SFTPAttributes(size: item.size, permissions: item.mode).write(to: &writer)
        return writer.bytes
    }

    func peer() -> ScriptedSFTPPeer {
        let offsets = Mutex([String: Int]())
        let children = children
        return ScriptedSFTPPeer { request in
            typealias B = SFTPBytes
            var reader = SFTPReader(request.body)
            let path = String(decoding: (try? reader.string()) ?? [], as: UTF8.self)
            switch request.type {
            case .lstat, .fstat:
                guard let item = self[path] else { return B.status(request.id, 2) }
                return B.packet(105, B.u32(request.id) + Self.fields(item))
            case .realpath:
                var resolved = path
                while let target = self[resolved]?.target { resolved = target }
                guard self[resolved] != nil else { return B.status(request.id, 2) }
                return B.name(request.id, [B.string(resolved) + B.string("") + B.attributeFields(mode: nil)])
            case .open:
                guard self[path]?.contents != nil else { return B.status(request.id, 2) }
                return B.handle(request.id, Array(path.utf8))
            case .read:
                let offset = Int((try? reader.uint64()) ?? 0)
                let length = Int((try? reader.uint32()) ?? 0)
                let contents = self[path]?.contents ?? []
                guard offset < contents.count else { return B.status(request.id, 1) }
                return B.data(
                    request.id, Array(contents[offset..<min(contents.count, offset + min(length, readCap))]))
            case .extended where path == "limits@openssh.com":
                return B.limits(request.id)
            case .opendir:
                guard self[path] != nil else { return B.status(request.id, 2) }
                return B.handle(request.id, Array(path.utf8))
            case .readdir:
                let names = children[path, default: []]
                let start = offsets.withLock { offsets in
                    defer { offsets[path, default: 0] += 1_000 }
                    return offsets[path, default: 0]
                }
                guard start < names.count else { return B.status(request.id, 1) }
                let batch = names[start..<min(start + 1_000, names.count)].map { child in
                    B.string((child as NSString).lastPathComponent) + B.string("") + Self.fields(self[child]!)
                }
                return B.name(request.id, batch)
            default:
                return B.status(request.id, 0)
            }
        }
    }
}
