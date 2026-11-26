/// Keys whose key-down went to the Mac (a ⌘ chord over the chrome in Integrated, a tab chord):
/// their repeats and key-up go there too, wherever the pointer is by then, until the key-up.
public struct MacChordKeys: Sendable {
    private var held: Set<UInt16> = []

    public init() {}

    /// `keyCode`'s key-down went to the Mac.
    public mutating func hold(_ keyCode: UInt16) { held.insert(keyCode) }

    /// Whether `event` belongs to a held chord key (its repeat or key-up); the key-up ends the
    /// hold. A fresh key-down of it is not taken: its route is decided anew.
    public mutating func take(_ event: MacKeyEvent) -> Bool {
        guard held.contains(event.keyCode) else { return false }
        switch event.kind {
        case .down(isRepeat: true): return true
        case .up:
            held.remove(event.keyCode)
            return true
        case .down(isRepeat: false):
            held.remove(event.keyCode)
            return false
        case .flagsChanged: return false
        }
    }
}
