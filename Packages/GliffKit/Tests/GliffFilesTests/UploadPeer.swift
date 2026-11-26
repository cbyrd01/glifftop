import Foundation
import GliffSFTP
import GliffTestSupport
import Synchronization
import Testing

@testable import GliffFiles

/// A scripted host for transfers: OPEN answers a new handle, WRITE is answered or held back
/// for the test to answer, LSTAT finds nothing, a folder lists empty, `statvfs` reports `space` bytes free, `limits`
/// names none, and anything else is OK. It counts the handles open at once.
final class UploadPeer: Sendable {
    private struct State {
        var holdsWrites = false
        var held: [UInt32] = []
        var nextHandle: UInt32 = 1
        var open: Set<[UInt8]> = []
        var mostOpen = 0
    }
    private final class Shared: Sendable {
        let lock = Mutex(State())
    }
    private let state: Shared
    let connection: ScriptedSFTPPeer

    /// An OPEN whose path holds `refusing` gets STATUS `code` instead of a handle.
    init(space: UInt64 = .max, refusing: String? = nil, code: UInt32 = 3) {
        let shared = Shared()
        state = shared
        connection = ScriptedSFTPPeer { request in
            if request.type == .open, let refusing, Self.path(request).contains(refusing) {
                return SFTPBytes.status(request.id, code)
            }
            return Self.answer(request, state: shared, space: space)
        }
    }

    var held: [UInt32] { state.lock.withLock { $0.held } }
    var mostOpen: Int { state.lock.withLock { $0.mostOpen } }
    var openNow: Int { state.lock.withLock { $0.open.count } }
    var writes: [PeerRequest] { connection.requests.filter { $0.type == .write } }

    /// Holds back each later WRITE's reply, or stops doing so.
    func holdWrites(_ holds: Bool) { state.lock.withLock { $0.holdsWrites = holds } }

    /// Answers the first `count` writes held back, OK.
    func answerHeld(_ count: Int = .max) {
        let ids = state.lock.withLock { state in
            let ids = state.held.prefix(count)
            state.held.removeFirst(ids.count)
            return Array(ids)
        }
        for id in ids { connection.send(SFTPBytes.status(id, 0)) }
    }

    private static func answer(_ request: PeerRequest, state: Shared, space: UInt64) -> [UInt8]? {
        typealias B = SFTPBytes
        var reader = SFTPReader(request.body)
        switch request.type {
        case .open:
            let handle = state.lock.withLock { state in
                defer { state.nextHandle += 1 }
                let handle = B.u32(state.nextHandle)
                state.open.insert(handle)
                state.mostOpen = max(state.mostOpen, state.open.count)
                return handle
            }
            return B.handle(request.id, handle)
        case .close:
            let handle = (try? reader.string()) ?? []
            state.lock.withLock { _ = $0.open.remove(handle) }
            return B.status(request.id, 0)
        case .write:
            let holds = state.lock.withLock { state in
                if state.holdsWrites { state.held.append(request.id) }
                return state.holdsWrites
            }
            return holds ? nil : B.status(request.id, 0)
        case .lstat, .stat:
            return B.status(request.id, 2)
        case .opendir:
            return B.handle(request.id)
        case .readdir:
            return B.status(request.id, 1)
        case .extended:
            switch String(decoding: (try? reader.string()) ?? [], as: UTF8.self) {
            case "statvfs@openssh.com":
                let numbers: [UInt64] = [4096, 1, 0, 0, space, 0, 0, 0, 0, 0, 255]
                return B.packet(201, B.u32(request.id) + numbers.flatMap(B.u64))
            case "limits@openssh.com":
                return B.limits(request.id)
            default:
                return B.status(request.id, 0)
            }
        default:
            return B.status(request.id, 0)
        }
    }

    /// The attributes an OPEN asked for.
    static func openAttributes(_ request: PeerRequest) throws -> SFTPAttributes {
        var reader = SFTPReader(request.body)
        _ = try reader.string()
        _ = try reader.uint32()
        return try SFTPAttributes(from: &reader)
    }

    /// The path an OPEN, MKDIR or RENAME (its source) named.
    static func path(_ request: PeerRequest) -> String {
        var reader = SFTPReader(request.body)
        return String(decoding: (try? reader.string()) ?? [], as: UTF8.self)
    }
}
