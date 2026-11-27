import Foundation

/// Keeps the app from being napped while a session runs: App Nap would slow a hidden app's
/// timers and I/O, so frames would be acknowledged late, which the server reads as congestion
/// and answers with a lower quality that takes minutes to climb back. The activity
/// (`userInitiatedAllowingIdleSystemSleep`) also keeps every timer at full rate while hidden
/// and turns off sudden and automatic termination, so a logout still ends the session with
/// its Bye; idle system sleep is still allowed. `begin` starts the hold and returns what ends
/// it.
public struct Awake: Sendable {
    let begin: @Sendable () -> @Sendable () -> Void

    public init(begin: @escaping @Sendable () -> @Sendable () -> Void) { self.begin = begin }

    /// The process's activity.
    public static let process = Awake {
        // The token is only ever handed back to `endActivity`, once.
        nonisolated(unsafe) let token = ProcessInfo.processInfo.beginActivity(
            options: .userInitiatedAllowingIdleSystemSleep, reason: "A remote session is streaming")
        return { ProcessInfo.processInfo.endActivity(token) }
    }
}
