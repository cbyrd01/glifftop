import AppKit
import GliffInput

/// One window's side of the pointer handover between a host's monitor windows
/// (`MonitorHandoverCoordinator`): its facts, read the same way for the key window and the
/// window under the pointer.
extension CaptureController {
    /// The window's facts as `MonitorHandover` reads them.
    var handoverFacts: HandoverFacts {
        HandoverFacts(
            group: handoverGroup, integrated: mode == .integrated,
            live: controller != nil && picture && !interrupted, released: controller?.isReleased ?? false,
            captured: isCaptured, hasSheet: window?.attachedSheet != nil)
    }
}
