import GliffClipboard
import GliffMachines
import GliffSession

/// The window's shared clipboard: its sharing, and Cancel on the host's read.
extension SessionModel {
    /// The sharing in force: the saved machine's (another window's change included), else the
    /// window's own; nil in either, Settings'.
    var clipboardInForce: ClipboardSharing { clipboardSharing(settings: AppSettings.clipboardSharing) }

    /// The sharing in force with Settings' `settings`. The window's own choice while its machine
    /// doesn't keep it yet (one made in the form, until the session streams).
    func clipboardSharing(settings: ClipboardSharing) -> ClipboardSharing {
        MachineOptions.clipboard(
            saved: clipboardUnsaved ? nil : machine, window: clipboardSharing, settings: settings)
    }

    /// The window chose a sharing: the machine keeps it, and the controller follows it. Kept
    /// even when it equals the window's last choice, as another window may have changed the
    /// machine's since.
    func clipboardSharingChanged() {
        if !applyingOptions { clipboardUnsaved = machine == nil }
        updateMachine { $0.clipboard = clipboardSharing }
        clipboard.sharingChanged()
    }

    /// Cancel on the host's read of the Mac clipboard: what is being served is aborted.
    func cancelClipboardServing() {
        guard let bridge = session?.clipboard else { return }
        Task { await bridge.cancelServing() }
    }
}
