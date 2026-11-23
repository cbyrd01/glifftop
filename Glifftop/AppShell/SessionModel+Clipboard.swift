import GliffClipboard
import GliffMachines
import GliffSession

/// The window's shared clipboard: its sharing, and Cancel on the host's read.
extension SessionModel {
    /// The sharing in force: the saved machine's (another window's change included), else the
    /// window's own; nil in either, Settings'.
    var clipboardInForce: ClipboardSharing {
        MachineOptions.clipboard(
            saved: machine, window: clipboardSharing, settings: AppSettings.clipboardSharing)
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
