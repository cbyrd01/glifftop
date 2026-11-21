import GliffProtocol

/// What a StreamConfig must satisfy before any decoder exists (upstream `net.rs`
/// `validate_stream_size` and `validate_view_size`), and which changes need a new decoder.
enum StreamRules {
    /// The decoder's largest side (upstream `MAX_DECODE`).
    static let maxSide: UInt32 = 4096
    /// What Hello offers, in preference order; a StreamConfig must pick from these.
    static let codecs: [Codec] = [.h264]
    static let chroma: [ChromaMode] = [.dual420, .single420]

    /// nil if valid, else the reason.
    static func validate(_ config: StreamConfig) -> String? {
        let side = maxSide
        guard codecs.contains(config.codec) else { return "unsupported codec \(config.codec)" }
        guard chroma.contains(config.chroma) else {
            return "unsupported chroma \(config.chroma)"
        }
        let (width, height) = (config.width, config.height)
        guard (1...side).contains(width), (1...side).contains(height), width % 2 == 0, height % 2 == 0 else {
            return "invalid stream dimensions \(width)x\(height); expected even dimensions within "
                + "\(side)x\(side) decoder limit"
        }
        // The view is the size the stream was scaled down from: never less than half of it.
        let (viewWidth, viewHeight) = (config.viewWidth, config.viewHeight)
        guard (1...side).contains(viewWidth), (1...side).contains(viewHeight),
            UInt64(viewWidth) * 2 >= UInt64(width), UInt64(viewHeight) * 2 >= UInt64(height)
        else {
            return "invalid view \(viewWidth)x\(viewHeight) for a \(width)x\(height) stream"
        }
        return nil
    }

    /// A monitor's sides: anything with area, up to far past any real monitor (16K). Unlike a
    /// stream's, a monitor's size needn't be even or decodable.
    static let monitorSides: ClosedRange<UInt32> = 1...16384

    /// `output`, if its size is one a monitor can have.
    static func monitor(_ output: OutputInfo) -> OutputInfo? {
        monitorSides.contains(output.width) && monitorSides.contains(output.height) ? output : nil
    }

    /// Whether the coded stream changed. Pace, view, scale and pipeline changes keep the
    /// decoder.
    static func needsNewDecoder(from old: StreamConfig, to new: StreamConfig) -> Bool {
        old.codec != new.codec || old.chroma != new.chroma || old.width != new.width
            || old.height != new.height || old.extradata != new.extradata
            || old.auxExtradata != new.auxExtradata
    }
}
