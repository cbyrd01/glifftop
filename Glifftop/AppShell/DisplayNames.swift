import Foundation
import GliffProtocol
import GliffSession
import GliffVideo

// What the app calls the stream's settings. App-side: GliffKit carries no UI text.

extension ChromaMode {
    var displayName: String {
        switch self {
        case .native444: "4:4:4"
        case .dual420: "4:4:4 as two 4:2:0 streams"
        case .single420: "4:2:0"
        }
    }
}

extension VideoError {
    /// Why video couldn't be set up, after "The video couldn't be decoded: ". The case name
    /// stays in brackets for a bug report.
    var setupFailure: String {
        switch self {
        case .noMetalDevice: "this Mac has no Metal GPU."
        default: "the GPU video pipeline couldn't be set up (\(self))."
        }
    }
}

extension VideoPipeline {
    var displayName: String {
        switch self {
        case .gpu: "GPU"
        case .cpu: "CPU"
        }
    }
}

extension VirtualResolution {
    var label: String {
        switch self {
        case .automatic: "Automatic"
        case .retina: "Retina"
        case .standard: "Standard"
        }
    }
}

extension TextSize {
    /// "Same as the Mac", else the factor as a percentage, and the remote scale when the
    /// display is known (e.g. "87.5% (1.75×)"): the layout's, as at Retina. Standard halves
    /// the pixels and that scale, not the layout.
    func label(backingScale: Double? = nil) -> String {
        guard self != .mac else { return "Same as the Mac" }
        let percent = (factor * 100).formatted(.number.precision(.fractionLength(0...1)))
        guard let backingScale else { return "\(percent)%" }
        let scale = remoteScale(backingScale: backingScale).formatted(
            .number.precision(.fractionLength(0...3)))
        return "\(percent)% (\(scale)×)"
    }
}
