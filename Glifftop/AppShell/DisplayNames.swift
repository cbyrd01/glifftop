import GliffProtocol
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
