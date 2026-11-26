public import GliffInput

/// An activation: motions that move the host's focus to this session's screen.
extension Session {
    /// How long input sent after an activation waits once its motions go. The host's focus takes
    /// a moment to follow them: a key that lands at once after them is lost, in neither the
    /// window left nor the one reached.
    public static let activationPause = Duration.milliseconds(50)

    /// Queues an activation's motions (`InputController.activate(at:)`) as `send` does; input
    /// sent after them waits `activationPause` from when they go.
    public nonisolated func activate(_ motions: [InputMessage]) {
        guard !motions.isEmpty else { return }
        motions.forEach(send)
        inputs.append(.pause(Self.activationPause))
    }
}
