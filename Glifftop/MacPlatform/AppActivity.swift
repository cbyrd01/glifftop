import AppKit
import Observation

/// Whether Glifftop is the active app, for SwiftUI views to observe (AppShell never asks AppKit).
@MainActor @Observable final class AppActivity {
    static let shared = AppActivity()

    private(set) var isActive = NSApplication.shared.isActive
    @ObservationIgnored private var observers: [any NSObjectProtocol] = []

    private init() {
        let changes = [
            (NSApplication.didBecomeActiveNotification, true),
            (NSApplication.didResignActiveNotification, false),
        ]
        for (name, active) in changes {
            observers.append(
                NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) {
                    [weak self] _ in
                    MainActor.assumeIsolated { self?.isActive = active }
                })
        }
    }
}
