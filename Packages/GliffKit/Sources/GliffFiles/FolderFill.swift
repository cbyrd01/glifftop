/// How a batch fills a top-level folder, either way: its items in the plan's order, each
/// folder made before what it holds, files several at once.
enum FolderFill {
    /// The most files a folder's transfer has open at once.
    static let filesAtOnce = 8

    /// A file's copy, which runs beside others.
    typealias Copy = @Sendable () async throws(FilesError) -> Void

    /// Runs `step` on each item in order (making a folder, or naming and creating a file); a
    /// step that returns a copy has it run as one of at most `atOnce`. The first failure stops
    /// new steps and cancels the copies running, and is thrown once they end; so does a cancel,
    /// which a step that sends no request (making a folder) wouldn't see.
    static func run<Item>(
        _ contents: some Sequence<Item>, atOnce: Int,
        step: (Item) async throws(FilesError) -> Copy?
    ) async throws(FilesError) {
        let failure = FirstFailure()
        await withTaskGroup(of: Void.self) { group in
            var running = 0
            for item in contents {
                guard failure.isClear else { break }
                guard !Task.isCancelled else {
                    failure.record(.cancelled)
                    break
                }
                let copy: Copy?
                do throws(FilesError) {
                    copy = try await step(item)
                } catch {
                    failure.record(error)
                    break
                }
                guard let copy else { continue }
                if running == atOnce {
                    await group.next()
                    running -= 1
                    guard failure.isClear else { break }
                }
                running += 1
                group.addTask {
                    do throws(FilesError) {
                        try await copy()
                    } catch {
                        failure.record(error)
                    }
                }
            }
            if !failure.isClear { group.cancelAll() }
            while await group.next() != nil {
                if !failure.isClear { group.cancelAll() }
            }
        }
        try failure.check()
    }
}
