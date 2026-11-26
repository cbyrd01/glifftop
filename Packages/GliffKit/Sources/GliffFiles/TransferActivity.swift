public import Foundation

/// Keeps the Mac awake and out of App Nap while a host's queue has work.
public protocol TransferActivity: Sendable {
    func begin() -> any NSObjectProtocol
    func end(_ token: any NSObjectProtocol)
}

/// `ProcessInfo`'s activity: user-initiated, with idle sleep held off.
public struct ProcessActivity: TransferActivity {
    public init() {}

    public func begin() -> any NSObjectProtocol {
        ProcessInfo.processInfo.beginActivity(
            options: [.userInitiated, .idleSystemSleepDisabled], reason: "Copying files")
    }

    public func end(_ token: any NSObjectProtocol) { ProcessInfo.processInfo.endActivity(token) }
}
