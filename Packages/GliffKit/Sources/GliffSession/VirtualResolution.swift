public import GliffProtocol

/// A virtual screen's resolution. Retina asks for every pixel of the window; Standard, on a
/// Retina display, for half a side (a quarter of the pixels) at half the scale, so the remote
/// layout is the same and an encoder that can't keep up has less to do; the scale may then be
/// under 1 (the server takes 0.5–4). The app draws that picture scaled to the window, whatever
/// Scale to Fit says. Automatic is Standard on a CPU pipeline, and Retina while the stream
/// hasn't named its pipeline (or names one this build doesn't know).
public enum VirtualResolution: String, CaseIterable, Codable, Sendable {
    case automatic, retina, standard

    /// Whether Standard's picture is asked for, display and window aside: Standard, or
    /// Automatic on a CPU pipeline.
    public func isStandard(pipeline: VideoPipeline?) -> Bool {
        switch self {
        case .retina: false
        case .standard: true
        case .automatic: pipeline == .cpu
        }
    }

    /// r, what a Resize's size and scale are multiplied by: ½ for Standard (or Automatic on a
    /// CPU pipeline) on a display of backing scale ≥ 2 whose window at ½ still fits the
    /// server's smallest screen (320×240); else 1.
    public func factor(pipeline: VideoPipeline?, backingScale: Double, width: UInt32, height: UInt32)
        -> Double
    {
        guard isStandard(pipeline: pipeline), backingScale >= 2, width / 2 >= 320, height / 2 >= 240 else {
            return 1
        }
        return 0.5
    }
}
