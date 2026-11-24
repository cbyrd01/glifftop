import Synchronization

/// The window's size and live resize, from any thread, into `ResizeRules`.
extension Session {
    /// The window's size in pixels, its backing scale and text size, from any thread. The
    /// latest goes to the server as a Resize while video is streaming, when `ResizeRules`
    /// says.
    public nonisolated func setViewTarget(_ target: ViewTarget) {
        viewTarget.withLock { $0 = target }
        Task { await self.takeViewTarget() }
    }

    /// The window's live resize (a drag of its edge) starts or ends, from any thread: no
    /// Resize goes during one, and the size it ended on goes at once. A session starts outside
    /// one, so the app tells a new session when its window is in one.
    public nonisolated func setLiveResize(_ on: Bool) {
        liveResizeEdges.withLock { $0.append(on) }
        Task { await self.takeViewTarget() }
    }

    private func takeViewTarget() async {
        guard !core.isFinished else { return }
        let edges = liveResizeEdges.withLock { edges in
            defer { edges.removeAll() }
            return edges
        }
        core.takeWindow(viewTarget.withLock { $0 }, liveResizeEdges: edges, now: Self.now())
        resizeWake?.cancel()
        // A little past the settle time; the tick sends it too, should this wake be lost.
        resizeWake = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(ResizeRules.settle + 20))
            guard !Task.isCancelled else { return }
            await self?.resizeIfDue()
        }
        await resizeIfDue()
    }

    private func resizeIfDue() async {
        await perform(core.resizeDue(now: Self.now()))
    }
}
