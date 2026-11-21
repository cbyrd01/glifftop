import Foundation
import GliffSession

/// A virtual screen's text size, as a factor of the Mac's backing scale: the same as
/// the Mac, or smaller steps that give the remote desktop more room. The remote scale is never
/// below 1 (`ViewTarget.virtualScale`), so on a 1× display every step is the Mac's own.
enum TextSize: Double, CaseIterable, Identifiable {
    case mac = 1
    case f875 = 0.875
    case f80 = 0.8
    case f75 = 0.75
    case f625 = 0.625
    case f50 = 0.5

    var id: Self { self }
    var factor: Double { rawValue }

    /// The remote screen's scale on a display of `backingScale`, as a Resize asks for it.
    func remoteScale(backingScale: Double) -> Double {
        ViewTarget.virtualScale(backingScale: backingScale, textFactor: factor)
    }

    /// "Same as the Mac", else the factor as a percentage, and the remote scale when the
    /// display is known (e.g. "87.5% (1.75×)").
    func label(backingScale: Double? = nil) -> String {
        guard self != .mac else { return "Same as the Mac" }
        let percent = (factor * 100).formatted(.number.precision(.fractionLength(0...1)))
        guard let backingScale else { return "\(percent)%" }
        let scale = remoteScale(backingScale: backingScale).formatted(
            .number.precision(.fractionLength(0...3)))
        return "\(percent)% (\(scale)×)"
    }

    /// Whether a larger step gives the same remote scale on this display: choosing it would
    /// change nothing.
    func changesNothing(backingScale: Double) -> Bool {
        let scale = remoteScale(backingScale: backingScale)
        return Self.allCases.contains {
            $0.factor > factor && $0.remoteScale(backingScale: backingScale) == scale
        }
    }
}
