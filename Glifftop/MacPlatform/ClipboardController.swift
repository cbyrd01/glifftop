import AppKit
import GliffClipboard
import GliffSession
import os

/// The Mac's side of the shared clipboard for one window's session: tells
/// `ClipboardPolicy` when the window comes to the front or leaves it, when the Mac clipboard
/// changes (its `changeCount`, polled twice a second, in front or not: a change behind still
/// withdraws our offer) and when the clipboard's sharing (`ClipboardSharing`) changes, and
/// carries out what it says through the session. Only the pasteboard's types are read here; the data is read when the
/// remote pastes (`PasteboardSource`).
final class ClipboardController {
    private static let log = Logger(subsystem: "me.cbyrd.Glifftop", category: "clipboard")
    /// The sharing in force for this window, read again whenever the app's defaults change
    /// (Settings, or a saved machine) and at `sharingChanged()`.
    private let inForce: () -> ClipboardSharing
    private var session: Session?
    /// The ssh destination as typed, which the paste panel names.
    private var host = ""
    private var policy: ClipboardPolicy
    /// The sharing as last read, which the policy was told.
    private var current: ClipboardSharing
    private var sharing: Bool { current != .off }
    private var includePasswords: Bool { current == .withPasswords }
    private var front = false
    private weak var window: NSWindow?
    private var changeCount = NSPasteboard.general.changeCount
    /// The pasteboard's count after we last put the remote's offer there.
    private var written: Int?
    /// What answers a paste of the remote's offer on the Mac, kept while it is on the pasteboard.
    private var provider: PasteProvider?
    /// The pasteboard's count and types as `mac()` last read them.
    private var lastRead: (changeCount: Int, types: [NSPasteboard.PasteboardType])?
    private var poll: Task<Void, Never>?
    private var windowObservers: [any NSObjectProtocol] = []
    private var observers: [any NSObjectProtocol] = []

    init(sharing inForce: @escaping () -> ClipboardSharing) {
        self.inForce = inForce
        current = inForce()
        policy = ClipboardPolicy(sharing: current != .off)
        for name in [NSApplication.didBecomeActiveNotification, NSApplication.didResignActiveNotification] {
            observers.append(observe(name, object: nil) { $0.frontChanged() })
        }
        observers.append(observe(UserDefaults.didChangeNotification, object: nil) { $0.sharingChanged() })
    }

    isolated deinit {
        (observers + windowObservers).forEach(NotificationCenter.default.removeObserver)
        poll?.cancel()
    }

    /// A session started: a fresh policy for it, the current clipboard offered if in front.
    func attach(_ session: Session, host: String) {
        detach()
        (self.session, self.host) = (session, host)
        current = inForce()
        policy = ClipboardPolicy(sharing: sharing)
        changeCount = NSPasteboard.general.changeCount
        front = isFront
        carryOut(policy.handle(.front(front, mac())))
        poll = Task { [weak self] in
            while true {
                do { try await Task.sleep(for: .milliseconds(500)) } catch { return }
                self?.pasteboardChecked()
            }
        }
    }

    /// The session is going or has ended: nothing more is offered to it, and the remote's copy
    /// we put on the Mac goes if it is still there: it can no longer be fetched, and the next
    /// session would otherwise offer it back as the Mac's.
    func detach() {
        poll?.cancel()
        poll = nil
        session = nil
        PasteProvider.afterPaste { [weak self] in self?.clearWritten() }
    }

    /// Clears the remote's copy we put on the Mac, if nothing has replaced it since.
    private func clearWritten() {
        if let written, NSPasteboard.general.changeCount == written { NSPasteboard.general.clearContents() }
        (written, provider) = (nil, nil)
    }

    /// Puts the remote's offer on the Mac, if `session` is still the one attached and the Mac
    /// clipboard is still at `judged`, the count the policy decided on: a Mac copy made since
    /// is never touched (the poll offers it instead).
    private func putOnMac(_ offer: RemoteClipboardOffer, from session: Session, judged: Int) {
        guard self.session === session, NSPasteboard.general.changeCount == judged,
            let bridge = session.clipboard
        else { return }
        // Only through this session's bridge, while sharing is on.
        let provider = PasteProvider(bridge: bridge, offer: offer, host: host) { [weak self] in
            guard let self else { return false }
            return sharing && self.session?.clipboard === bridge
        }
        guard let count = RemotePasteboard.write(offer, provider: provider) else { return }
        Self.log.info("remote clipboard put on the Mac")
        ClipboardOrigin.record(changeCount: count, destination: host)
        (self.provider, written, changeCount) = (provider, count, count)
        carryOut(policy.handle(.wrote(changeCount: count)))
    }

    /// The window the session shows in (`ClipboardTracker`).
    func update(window: NSWindow?) {
        guard window !== self.window else { return }
        self.window = window
        windowObservers.forEach(NotificationCenter.default.removeObserver)
        windowObservers = []
        if let window {
            for name in [NSWindow.didBecomeKeyNotification, NSWindow.didResignKeyNotification] {
                windowObservers.append(observe(name, object: window) { $0.frontChanged() })
            }
        }
        frontChanged()
    }

    /// In front: the app active and the session's window key.
    private var isFront: Bool { NSApplication.shared.isActive && window?.isKeyWindow == true }

    private func frontChanged() {
        let now = isFront
        guard now != front else { return }
        front = now
        carryOut(policy.handle(.front(now, mac())))
    }

    /// The sharing in force may have changed. Both switches change before either is judged: a
    /// sharing change sees the passwords setting as it now is.
    func sharingChanged() {
        let (wasSharing, wasIncluding) = (sharing, includePasswords)
        current = inForce()
        if sharing != wasSharing { carryOut(policy.handle(.sharing(sharing, mac()))) }
        if includePasswords != wasIncluding { carryOut(policy.handle(.recheck(mac()))) }
    }

    /// The host's clipboard changed: ours is no longer there, so withdrawing it later sends no
    /// empty offer over the host's copy.
    func remoteOffered(_ offer: RemoteClipboardOffer) {
        carryOut(policy.handle(.remoteOffer(offer, mac())))
    }

    private func pasteboardChecked() {
        let count = NSPasteboard.general.changeCount
        guard count != changeCount else { return }
        changeCount = count
        carryOut(policy.handle(.macChanged(mac())))
    }

    /// The Mac clipboard as the policy sees it, from its types alone, kept as `lastRead` for the
    /// offer made from it. The types belong to the count: read again if another app wrote
    /// between.
    private func mac() -> ClipboardPolicy.MacClipboard {
        let pasteboard = NSPasteboard.general
        var read: (changeCount: Int, types: [NSPasteboard.PasteboardType])
        repeat {
            read = (pasteboard.changeCount, pasteboard.types ?? [])
        } while pasteboard.changeCount != read.changeCount
        lastRead = read
        // The remote's copy we put there is never offered back as the Mac's (it is still there
        // after a session's end while a paste is being answered), nor one another window's
        // session to this host put there.
        return ClipboardPolicy.MacClipboard(
            changeCount: read.changeCount,
            offerable: read.changeCount != written
                && ClipboardPolicy.offerable(
                    typeCount: PasteboardTypes.mimes(for: read.types).count,
                    isPassword: PasteboardTypes.isPassword(read.types), includePasswords: includePasswords,
                    cameFromThisHost: ClipboardOrigin.destination(of: read.changeCount) == host)
        )
    }

    private func carryOut(_ actions: [ClipboardPolicy.Action]) {
        guard let session else { return }
        for action in actions {
            switch action {
            case .offerMac(let count):
                // The types the policy judged, never read again: they could be another copy's.
                guard let lastRead, lastRead.changeCount == count else { continue }
                let mimes = PasteboardTypes.mimes(for: lastRead.types)
                Self.log.info("Mac clipboard offered: \(mimes.count, privacy: .public) types")
                session.offerClipboard(
                    LocalClipboardOffer(
                        mimeTypes: mimes, token: count, isPassword: PasteboardTypes.isPassword(lastRead.types)
                    )
                )
            case .revokeMac(let sendEmpty):
                Self.log.info("Mac clipboard withdrawn, empty offer: \(sendEmpty, privacy: .public)")
                session.revokeClipboard(sendEmpty: sendEmpty)
            case .putOnMac(let offer):
                // What the policy just read (`mac()`), not the last poll.
                let judged = lastRead?.changeCount ?? changeCount
                PasteProvider.afterPaste { [weak self] in self?.putOnMac(offer, from: session, judged: judged)
                }
            case .clearOwned:
                PasteProvider.afterPaste { [weak self] in self?.clearWritten() }
            }
        }
    }

    private func observe(
        _ name: Notification.Name, object: AnyObject?,
        _ action: @escaping @MainActor (ClipboardController) -> Void
    ) -> any NSObjectProtocol {
        NotificationCenter.default.addObserver(forName: name, object: object, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                if let self { action(self) }
            }
        }
    }
}
