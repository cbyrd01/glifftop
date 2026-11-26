/// One reader of a session's `RemotePointerSlot` for a confined pointer: confinement starts
/// from one look at the slot (`start`, what `InputController.confine` takes), and each look
/// after gives every report since the last (`reports`, what `InputController.followHost` takes).
public struct HostPointerFollower: Sendable {
    public let slot: RemotePointerSlot
    /// The slot's generation last looked at.
    private var seen: UInt64 = 0

    public init(_ slot: RemotePointerSlot) { self.slot = slot }

    /// One look at the host's pointer, after which only newer reports come: its last report,
    /// where it hid its pointer if that report did, and whether that report announced a new
    /// picture (nil after reports began).
    public mutating func start() -> (
        latest: RemotePointerSlot.Position?, hiddenAt: (bufferX: Double, bufferY: Double)?, newPicture: Bool
    ) {
        let (latest, generation) = slot.read()
        seen = generation
        let hiddenAt = latest.flatMap { $0.visible ? nil : (bufferX: $0.x, bufferY: $0.y) }
        return (latest, hiddenAt, generation > 0 && latest == nil)
    }

    /// The reports since the last look, oldest first, in capture-buffer pixels; nil: a new
    /// picture (or the session's end).
    public mutating func reports() -> [(bufferX: Double, bufferY: Double, visible: Bool)?] {
        let reports = slot.reports(after: seen)
        seen = reports.generation
        return reports.positions.map { $0.map { ($0.x, $0.y, $0.visible) } }
    }
}
