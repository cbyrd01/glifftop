import Foundation
import GliffTransport
import Observation

/// A host's monitors, listed on request (Get Screens, Refresh Screen List) and never
/// saved: the list, whether a listing runs, and why the last one has no list. One listing at a
/// time; the list belongs to the host it was listed for.
@Observable final class ScreenList {
    /// The monitors last listed for `host`.
    private(set) var screens: [RemoteScreen] = []
    private(set) var isListing = false
    /// Why the last listing has no list, to show.
    private(set) var error: String?
    /// The host the list, listing or error is for, as typed but trimmed as `SSHTarget` trims it,
    /// so it compares equal to a session's `SSHTarget.value`.
    @ObservationIgnored private(set) var host: String?
    @ObservationIgnored private var listing: Task<Void, Never>?
    /// Lists a host's monitors: over ssh (a closure, so another way of listing can replace it).
    @ObservationIgnored private let lister:
        @Sendable (SSHTarget) async throws(ScreenListError) -> [RemoteScreen]

    init(
        lister: @escaping @Sendable (SSHTarget) async throws(ScreenListError) -> [RemoteScreen] = ScreenList
            .overSSH
    ) {
        self.lister = lister
    }

    /// Lists `host`'s monitors, replacing a listing still running. A list for the same host
    /// stays while the new one runs, so a refresh keeps what is chosen from it; a listing that
    /// fails leaves no list, as a stale one could offer a monitor that's gone.
    func list(host typed: String) {
        let host = Self.key(typed)
        forget(unless: host)
        stop()
        self.host = host
        error = nil
        let target: SSHTarget
        do {
            target = try SSHTarget(host)
        } catch {
            self.error = error.message
            return
        }
        isListing = true
        let lister = lister
        listing = Task {
            let result: Result<[RemoteScreen], ScreenListError>
            do throws(ScreenListError) {
                result = .success(try await lister(target))
            } catch {
                result = .failure(error)
            }
            // Stopped or replaced meanwhile: that listing's answer is no longer wanted.
            guard !Task.isCancelled else { return }
            isListing = false
            switch result {
            case .success(let listed):
                screens = listed
                if listed.isEmpty { error = "The host has no monitors to show." }
            case .failure(let failure):
                screens = []
                error = failure.message
            }
        }
    }

    /// Forgets the list, any listing and its error unless they are for `host`: the field now
    /// names another host.
    func forget(unless host: String) {
        guard Self.key(host) != self.host else { return }
        stop()
        screens = []
        error = nil
        self.host = nil
    }

    /// Stops a listing still running (its ssh ends), keeping the list but not its error: a
    /// session is starting, and the form's error isn't the session's.
    func stop() {
        listing?.cancel()
        listing = nil
        isListing = false
        error = nil
    }

    /// Whether `choice` can be used for `host`: a named monitor only from this host's list.
    func allows(_ choice: ScreenChoice, host: String) -> Bool {
        guard case .named(let name) = choice else { return true }
        return Self.key(host) == self.host && screens.contains { $0.name == name }
    }

    /// Whether the list is for `host` (as typed, or a session's `SSHTarget.value`).
    func isFor(_ host: String) -> Bool { Self.key(host) == self.host }

    private static func key(_ host: String) -> String { host.trimmingCharacters(in: .whitespacesAndNewlines) }

    /// The ssh lister: one `ssh` running the host's list command.
    static func overSSH(_ target: SSHTarget) async throws(ScreenListError) -> [RemoteScreen] {
        try await ScreenLister(command: ScreenListCommand(target: target)).screens()
    }
}
