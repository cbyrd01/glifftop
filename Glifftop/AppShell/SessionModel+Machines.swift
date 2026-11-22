import Foundation
import GliffMachines
import GliffSession
import GliffTransport

/// The session's machine: connecting with a machine's options, recording it when a session
/// streams, and keeping the options changed during a session (View ▸ Text Size, Resolution,
/// Scale to Fit, Screen) on it.
extension SessionModel {
    /// The session's saved machine: the one kept for its destination, whatever the sheet
    /// changed since. Nil without a session, and for a host that hasn't streamed yet.
    var machine: Machine? { isActive ? machines.list.machine(for: host) : nil }

    /// The options the window's session runs with now.
    var currentOptions: MachineOptions {
        MachineOptions(
            screen: screenChoice, textSize: textSize, resolution: resolution, scaleToFit: scaleToFit,
            reconnects: reconnects)
    }

    /// Starts a session with `target` (as typed) and `options`; its machine is added when it
    /// first streams. Throws, with the reason to show, when the target isn't a valid ssh
    /// destination.
    func connect(to target: String, options: MachineOptions) throws(SSHTargetError) {
        let destination = try SSHTarget(target)
        guard !quitting else { return }
        cancelReconnect()
        apply(options)
        start(destination, screen: options.screen)
    }

    /// The session streamed: its machine, added if new, now has the window's options and the
    /// date. A reconnect's try repeats the session's screen, and leaves the machine's be (the
    /// sheet may have changed it).
    func recordConnection() {
        var options = currentOptions
        if keepsWindow, let kept = machine { options.screen = kept.options.screen }
        machines.connected(host, options: options)
    }

    /// The sheet saved `saved`: if it's this session's machine, its options apply, but for the
    /// screen, which takes a new session (the next connection, Try Again, or View ▸ Screen).
    func machineSaved(_ saved: Machine) {
        guard machine?.id == saved.id else { return }
        apply(saved.options)
        sheetScreen = saved.options.screen == screenChoice ? nil : saved.options.screen
    }

    /// Connection ▸ Edit Machine…: the session's machine in the sheet.
    func editMachine() {
        guard let machine else { return }
        machineEdit = MachineEdit(machine: machine, isNew: false)
    }

    /// New Machine… (⌘N, the + button): an empty machine with Settings' options in the sheet.
    func newMachine() {
        machineEdit = MachineEdit(
            machine: Machine(name: "", destination: "", options: AppSettings.defaultOptions), isNew: true)
    }

    /// An option changed during the session: kept on the session's machine, if it has one.
    func updateMachine(_ change: (inout MachineOptions) -> Void) {
        guard !applyingOptions, var kept = machine else { return }
        change(&kept.options)
        guard kept != machine else { return }
        machines.save(kept)
    }

    /// The window's options from `options`, but for the screen (a session's own); none of them
    /// a change to keep.
    private func apply(_ options: MachineOptions) {
        applyingOptions = true
        defer { applyingOptions = false }
        scaleToFit = options.scaleToFit
        textSize = options.textSize
        resolution = options.resolution
        reconnects = options.reconnects
    }
}
