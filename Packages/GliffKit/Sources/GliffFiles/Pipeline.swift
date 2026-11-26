import Synchronization

/// The flow of a host's transfers: blocks of 32 KiB (OpenSSH's own figure, or less as the
/// server's limits say), at most `window` requests in flight across every file of a batch.
///
/// The window can be set lower or higher at any time (8 while a session window to the host
/// streams, so the picture never queues behind file data); a new size applies at the next
/// request, and requests already out finish.
public final class Pipeline: Sendable {
    public static let blockSize: UInt32 = 32 * 1024
    public static let fullWindow = 64
    public static let streamingWindow = 8

    private struct Waiter {
        let id: Int
        let continuation: CheckedContinuation<Bool, Never>
    }

    private struct State {
        var window: Int
        var inFlight = 0
        var nextID = 0
        var waiters: [Waiter] = []

        /// Takes slots for waiters, first come first served, while the window has room.
        mutating func admit() -> [Waiter] {
            var admitted: [Waiter] = []
            while inFlight < window, !waiters.isEmpty {
                inFlight += 1
                admitted.append(waiters.removeFirst())
            }
            return admitted
        }
    }

    private let state: Mutex<State>

    public init(window: Int = fullWindow) {
        state = Mutex(State(window: max(1, window)))
    }

    /// Sets the most requests in flight, at least 1.
    public func setWindow(_ window: Int) {
        let admitted = state.withLock { state in
            state.window = max(1, window)
            return state.admit()
        }
        for waiter in admitted { waiter.continuation.resume(returning: true) }
    }

    /// Waits for a slot in the window; a cancelled caller gets none and throws `.cancelled`.
    func acquire() async throws(FilesError) {
        let id = state.withLock { state in
            defer { state.nextID += 1 }
            return state.nextID
        }
        let granted = await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                let now: Bool? = state.withLock { state in
                    if Task.isCancelled { return false }
                    if state.waiters.isEmpty, state.inFlight < state.window {
                        state.inFlight += 1
                        return true
                    }
                    state.waiters.append(Waiter(id: id, continuation: continuation))
                    return nil
                }
                if let now { continuation.resume(returning: now) }
            }
        } onCancel: {
            let waiter = state.withLock { state in
                state.waiters.firstIndex { $0.id == id }.map { state.waiters.remove(at: $0) }
            }
            waiter?.continuation.resume(returning: false)
        }
        guard granted else { throw .cancelled }
    }

    /// Gives a slot back.
    func release() {
        let admitted = state.withLock { state in
            state.inFlight -= 1
            return state.admit()
        }
        for waiter in admitted { waiter.continuation.resume(returning: true) }
    }

    /// Writes the first `count` bytes of `file` to the open `handle`, a block per request
    /// within the window, adding each block to `progress` once the host has it. The first
    /// failure stops new writes, and is thrown once the writes out have finished; a file
    /// shorter than `count` now fails as this Mac's.
    func send(
        _ file: LocalFile, count: UInt64, to handle: [UInt8], on session: SFTPSession, block: UInt32,
        progress: TransferProgress
    ) async throws(FilesError) {
        try await each(stride(from: 0, to: count, by: Int(block))) { (offset) async throws(FilesError) in
            let length = Int(min(UInt64(block), count - offset))
            let bytes = try file.read(at: offset, count: length)
            guard bytes.count == length else { throw .local(.failure) }
            try await session.write(handle: handle, offset: offset, data: bytes)
            progress.add(bytes: UInt64(length))
        }
    }

    /// How far past its planned size a download may run before it fails as changed.
    static let slack: UInt64 = 1 << 20

    /// Reads the open `handle` into `file`, a block per request within the window, writing each
    /// reply at its offset and adding it to `progress`. Each read stops at `count`, and one more,
    /// at `count`, confirms the end in the same window, so a small file costs two reads; a short
    /// read re-asks for the rest at its offset. A file that ends before `count` (a hole would be
    /// left), or still goes on past `count` plus `slack`, fails `.changedWhileCopying`; one that
    /// grew less arrives whole.
    func receive(
        _ handle: [UInt8], count: UInt64, into file: LocalFile, on session: SFTPSession, block: UInt32,
        progress: TransferProgress
    ) async throws(FilesError) {
        let size = UInt64(block)
        let reads = count / size + (count % size == 0 ? 0 : 1)
        let grew = Flag()
        try await each(0...reads) { (index) async throws(FilesError) in
            let offset = index == reads ? count : index * size
            let length = UInt32(min(size, count - offset))
            let read = try await Self.read(
                handle, at: offset, length: length == 0 ? block : length, into: file, on: session,
                progress: progress)
            if length == 0 {
                if read == size { grew.set() }
            } else if read < length {
                throw .changedWhileCopying
            }
        }
        // The file grew by a block or more: read on, one block at a time, within the slack (a
        // count of blocks, so a hostile size can't overflow it).
        var offset = count
        for _ in 0..<(grew.isSet ? Self.slack / size : 0) {
            offset &+= size
            try await acquire()
            defer { release() }
            let read = try await Self.read(
                handle, at: offset, length: block, into: file, on: session, progress: progress)
            guard read == size else { return }
        }
        if grew.isSet { throw .changedWhileCopying }
    }

    /// Reads `length` bytes at `offset` into `file`, re-asking after a short read; how many came
    /// before the file ended.
    private static func read(
        _ handle: [UInt8], at offset: UInt64, length: UInt32, into file: LocalFile, on session: SFTPSession,
        progress: TransferProgress
    ) async throws(FilesError) -> UInt64 {
        var done: UInt64 = 0
        while done < length {
            // The session ends on empty DATA, or DATA longer than asked.
            guard
                let bytes = try await session.read(
                    handle: handle, offset: offset + done, length: length - UInt32(done))
            else { break }
            try file.write(bytes, at: offset + done)
            progress.add(bytes: UInt64(bytes.count))
            done += UInt64(bytes.count)
        }
        return done
    }

    /// Runs `request` for each element, as many at once as the window allows. The first
    /// failure stops new requests, and is thrown once those out have finished.
    func each<Element: Sendable>(
        _ elements: some Sequence<Element>,
        _ request: @escaping @Sendable (Element) async throws(FilesError) -> Void
    ) async throws(FilesError) {
        let failure = FirstFailure()
        await withDiscardingTaskGroup { group in
            for element in elements {
                guard failure.isClear else { break }
                do throws(FilesError) {
                    try await acquire()
                } catch {
                    failure.record(error)
                    break
                }
                group.addTask {
                    defer { self.release() }
                    do throws(FilesError) {
                        try await request(element)
                    } catch {
                        failure.record(error)
                    }
                }
            }
        }
        try failure.check()
    }
}

/// Whether a download's read past its planned size found a whole block more.
private final class Flag: Sendable {
    private let state = Atomic(false)

    var isSet: Bool { state.load(ordering: .relaxed) }

    func set() { state.store(true, ordering: .relaxed) }
}
