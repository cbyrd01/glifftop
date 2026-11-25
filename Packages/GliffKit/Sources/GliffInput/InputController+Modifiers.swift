/// The held modifiers, synced from an event's flags before it goes to the host: a modifier
/// pressed where its press went to the Mac (before capture, over the chrome) joins the next
/// click, scroll or key, and one whose release went missing is let go.
extension InputController {
    /// The stale releases (last pressed first), then the missing presses, never for `code`
    /// itself (a modifier's own event sends its own press or release).
    mutating func syncModifiers(_ flags: UInt, except code: UInt32? = nil) -> [InputMessage] {
        releaseStaleModifiers(flags, except: code) + pressMissingModifiers(flags, except: code)
    }

    /// Releases for modifiers the remote holds that `flags` says are up, last pressed first.
    mutating func releaseStaleModifiers(_ flags: UInt, except code: UInt32? = nil) -> [InputMessage] {
        let up = MacKeyTranslator.modifiersUp(flags)
        return ledger.heldKeys.filter { up.contains($0) && $0 != code }.reversed()
            .compactMap { ledger.release(key: $0) }
    }

    /// Presses for modifiers `flags` says are down that the remote doesn't hold. `code` counts
    /// as held: a flag with no side bit (a posted event) is then that side, not the other.
    private mutating func pressMissingModifiers(_ flags: UInt, except code: UInt32? = nil) -> [InputMessage] {
        var held = Set(ledger.heldKeys)
        if let code { held.insert(code) }
        return MacKeyTranslator.modifiersDown(flags, holding: held).filter { !held.contains($0) }
            .flatMap { ledger.press(key: $0) }
    }
}
