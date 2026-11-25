import AppKit
import GliffClipboard

/// The app's one `HostClipboardLedger`: one clipboard per host across its windows. Each
/// window's `ClipboardController` registers its session here and reports what it does; this
/// tells the others when their offer is superseded or the copy is handed to them, and holds an
/// offer made inside the fence until the fence ends. An id not registered (a controller with no
/// session) is ignored.
final class HostClipboards {
    static let shared = HostClipboards()

    private var ledger = HostClipboardLedger()
    private let clock = ContinuousClock()
    private let origin: ContinuousClock.Instant
    private var controllers: [UUID: Entry] = [:]
    /// Offers waiting for the fence, by session: a later offer, a withdrawal or the end replaces
    /// it.
    private var waiting: [UUID: Task<Void, Never>] = [:]

    private struct Entry {
        weak var controller: ClipboardController?
    }

    private init() { origin = clock.now }

    private var now: Duration { clock.now - origin }

    private var macCount: Int { NSPasteboard.general.changeCount }

    /// Set when the app quits: nothing is handed over.
    var quitting: Bool {
        get { ledger.quitting }
        set { ledger.quitting = newValue }
    }

    func register(_ controller: ClipboardController, id: UUID, host: String, sharing: Bool) {
        controllers[id] = Entry(controller: controller)
        ledger.register(id, host: host, sharing: sharing)
    }

    func sharing(_ id: UUID, _ on: Bool) {
        handOver(ledger.sharing(id, on, macCount: macCount))
    }

    func front(_ id: UUID) { ledger.front(id, at: now) }

    func heldElsewhere(_ id: UUID, changeCount: Int) -> Bool {
        ledger.heldElsewhere(id, changeCount: changeCount)
    }

    /// The session offers the Mac clipboard: the host's other sessions are told theirs is
    /// superseded, and `send` runs now, or when the fence after the host's last empty offer
    /// ends.
    func offer(_ id: UUID, changeCount: Int, send: @escaping @MainActor () -> Void) {
        cancelWaiting(id)
        let result = ledger.offered(id, changeCount: changeCount, at: now)
        for other in result.superseded {
            // An older offer still waiting for the fence must not land over this one.
            cancelWaiting(other)
            controllers[other]?.controller?.superseded()
        }
        guard let sendAt = result.sendAt else { return send() }
        waiting[id] = Task { [clock, origin] in
            do { try await clock.sleep(until: origin + sendAt) } catch { return }
            // Cancelled after the sleep ended, while queued: replaced or withdrawn.
            guard !Task.isCancelled else { return }
            self.waiting[id] = nil
            send()
        }
    }

    /// The session withdraws its offer; false when it sends nothing: it is detaching, or its
    /// offer was still waiting, never sent.
    func withdrew(_ id: UUID, empty: Bool) -> Bool {
        let wasWaiting = cancelWaiting(id)
        return ledger.withdrew(id, empty: empty, at: now) && !wasWaiting
    }

    /// The session's host reported a copy; false for a stale empty one the session ignores.
    func hostCopy(_ id: UUID, isFirst: Bool, isEmpty: Bool) -> Bool {
        ledger.hostCopy(id, isFirst: isFirst, isEmpty: isEmpty, at: now)
    }

    /// The session ended or is going: the copy it held goes to another session to the host,
    /// and it is forgotten.
    func detach(_ id: UUID) {
        cancelWaiting(id)
        let handovers = ledger.detaching([id], macCount: macCount)
        ledger.closed(id)
        controllers[id] = nil
        handOver(handovers)
    }

    /// Closes every tab of a group (⇧⌘W) with `close`, telling the ledger first, so the tabs
    /// don't hand the copy to each other one by one. A tab still open after (a sheet up) is an
    /// ordinary session again.
    func closeGroup(_ windows: [NSWindow], close: (NSWindow) -> Void) {
        let closing = sessions(in: windows)
        for id in closing { cancelWaiting(id) }
        handOver(ledger.detaching(Set(closing), macCount: macCount))
        // A background tab isn't visible either: the closed ones are those that said so.
        var closed: Set<ObjectIdentifier> = []
        let observer = NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification, object: nil, queue: nil
        ) { notice in
            let window = notice.object.map { ObjectIdentifier($0 as AnyObject) }
            MainActor.assumeIsolated { if let window { closed.insert(window) } }
        }
        for window in windows { close(window) }
        NotificationCenter.default.removeObserver(observer)
        ledger.stayed(Set(sessions(in: windows.filter { !closed.contains(ObjectIdentifier($0)) })))
    }

    private func sessions(in windows: [NSWindow]) -> [UUID] {
        controllers.compactMap { id, entry in
            let window = entry.controller?.window
            return windows.contains { $0 === window } ? id : nil
        }
    }

    /// Each host's candidates in turn, until one offers.
    private func handOver(_ handovers: [HostClipboardLedger.Handover]) {
        for handover in handovers {
            for candidate in handover.candidates where controllers[candidate]?.controller?.handOver() == true
            {
                break
            }
        }
    }

    /// Cancels the session's offer waiting for the fence; whether there was one.
    @discardableResult
    private func cancelWaiting(_ id: UUID) -> Bool {
        guard let task = waiting.removeValue(forKey: id) else { return false }
        task.cancel()
        return true
    }
}
