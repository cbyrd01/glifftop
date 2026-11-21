internal import CoreMedia
internal import CoreVideo
import Synchronization
internal import VideoToolbox

/// Why an access unit gave no picture.
enum StreamDecodeFailure: Error, Equatable {
    /// No SPS/PPS seen since the start or the last invalidation: only an IDR can start.
    case awaitingKeyframe
    /// The access unit carried no slice, or VideoToolbox returned no image.
    case noPicture
    /// VideoToolbox kept the picture past its own call (it would come out a frame late, to
    /// nobody). No picture, but no reset: a stream VideoToolbox always holds would otherwise
    /// ask for a keyframe on every keyframe. `VideoToolboxDecoder` logs it once per stream.
    case held
    /// More NAL units than `AnnexB.maxUnits`: no real encoder sends that.
    case tooManyUnits
    /// The SPS's picture (its cropped display size) isn't the StreamConfig's: refused, not
    /// cropped or padded (upstream's `check_stream_size`).
    case streamSize(width: Int32, height: Int32)
    case formatDescription(Int32)
    case session(Int32)
    case sampleBuffer(Int32)
    case decode(Int32)

    /// Only no picture came out (a dropped frame, no slices, a held frame): nothing is broken.
    var isNoPicture: Bool { self == .noPicture || self == .held }

    /// A real failure: the session and parameter sets are dropped and the stream waits for
    /// the next IDR. Waiting for a keyframe already is that state, so it doesn't reset again.
    var resetsTheStream: Bool {
        switch self {
        case .awaitingKeyframe, .noPicture, .held: false
        case .tooManyUnits, .streamSize, .formatDescription, .session, .sampleBuffer, .decode: true
        }
    }
}

/// One H.264 stream through one VideoToolbox session, decoded synchronously: each access unit's
/// picture comes back from its own `decode` call. Owned by one isolation domain (not Sendable).
final class StreamDecoder {
    /// The parameter sets in force and the format made from them; nil until an IDR.
    private var current: (sets: ParameterSets, format: CMVideoFormatDescription)?
    private var session: VTDecompressionSession?
    /// The StreamConfig's picture size: an SPS for any other is refused. Nil accepts any.
    var expectedSize: PixelSize?

    init() {}

    deinit {
        if let session { VTDecompressionSessionInvalidate(session) }
    }

    /// Decodes one Annex B access unit. Parameter sets that come with an IDR and differ from
    /// the current ones replace the format (and the session, if it can't take the new one).
    /// Any failure but a missing picture resets the decoder to wait for the next IDR, since
    /// the frames after it would decode against missing references.
    func decode(_ accessUnit: ArraySlice<UInt8>) throws(StreamDecodeFailure) -> CVPixelBuffer {
        let units = AnnexB.units(in: accessUnit)
        do throws(StreamDecodeFailure) {
            guard units.count <= AnnexB.maxUnits else { throw .tooManyUnits }
            if units.contains(where: { $0.type == NALUnit.idr }), let sets = ParameterSets(units),
                sets != current?.sets
            {
                let format = try Self.formatDescription(sets)
                let size = CMVideoFormatDescriptionGetDimensions(format)
                if let expectedSize,
                    PixelSize(width: Int(size.width), height: Int(size.height)) != expectedSize
                {
                    throw .streamSize(width: size.width, height: size.height)
                }
                if let session,
                    !VTDecompressionSessionCanAcceptFormatDescription(session, formatDescription: format)
                {
                    dropSession()
                }
                current = (sets, format)
            }
            guard let format = current?.format else { throw .awaitingKeyframe }
            let sample = try Self.sampleBuffer(units, format: format)
            if let session { return try decode(sample, in: session) }
            let made = try Self.makeSession(format)
            session = made
            return try decode(sample, in: made)
        } catch {
            if error.resetsTheStream { invalidate() }
            throw error
        }
    }

    /// Drops the session and the parameter sets: only the next IDR (with its SPS/PPS) restarts.
    func invalidate() {
        dropSession()
        current = nil
    }

    private func dropSession() {
        if let session { VTDecompressionSessionInvalidate(session) }
        session = nil
    }

    private func decode(_ sample: CMSampleBuffer, in session: VTDecompressionSession)
        throws(StreamDecodeFailure) -> CVPixelBuffer
    {
        // Without asynchronous decompression the handler runs before DecodeFrame returns, on a
        // VideoToolbox thread.
        let output = DecodeOutput()
        let callStatus = VTDecompressionSessionDecodeFrame(
            session, sampleBuffer: sample, flags: [], infoFlagsOut: nil
        ) { status, flags, image, _, _ in
            let image = Handed(image: flags.contains(.frameDropped) ? nil : image)
            output.result.withLock { $0 = (status, image) }
        }
        guard callStatus == noErr else { throw .decode(callStatus) }
        guard let (status, handed) = output.result.withLock({ $0 }) else { throw .held }
        guard status == noErr else { throw .decode(status) }
        guard let image = handed.image else { throw .noPicture }
        return image
    }

    /// A format description from an SPS and PPS (4-byte NAL lengths).
    static func formatDescription(_ sets: ParameterSets) throws(StreamDecodeFailure)
        -> CMVideoFormatDescription
    {
        var format: CMFormatDescription?
        let status = sets.sps.withUnsafeBufferPointer { sps in
            sets.pps.withUnsafeBufferPointer { pps in
                guard let spsBase = sps.baseAddress, let ppsBase = pps.baseAddress else {
                    return kCMFormatDescriptionError_InvalidParameter
                }
                return CMVideoFormatDescriptionCreateFromH264ParameterSets(
                    allocator: nil, parameterSetCount: 2, parameterSetPointers: [spsBase, ppsBase],
                    parameterSetSizes: [sps.count, pps.count], nalUnitHeaderLength: 4,
                    formatDescriptionOut: &format)
            }
        }
        guard status == noErr, let format else { throw .formatDescription(status) }
        return format
    }

    private static func makeSession(_ format: CMVideoFormatDescription) throws(StreamDecodeFailure)
        -> VTDecompressionSession
    {
        var specification: [CFString: Any] = [:]
        #if os(macOS)
            specification[kVTVideoDecoderSpecification_RequireHardwareAcceleratedVideoDecoder] = true
        #endif
        let attributes: [CFString: Any] = [
            kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
            kCVPixelBufferMetalCompatibilityKey: true,
            kCVPixelBufferIOSurfacePropertiesKey: [CFString: Any](),
        ]
        var session: VTDecompressionSession?
        let status = VTDecompressionSessionCreate(
            allocator: nil, formatDescription: format, decoderSpecification: specification as CFDictionary,
            imageBufferAttributes: attributes as CFDictionary, outputCallback: nil,
            decompressionSessionOut: &session)
        guard status == noErr, let session else { throw .session(status) }
        let realTime = VTSessionSetProperty(
            session, key: kVTDecompressionPropertyKey_RealTime, value: kCFBooleanTrue)
        guard realTime == noErr else {
            VTDecompressionSessionInvalidate(session)
            throw .session(realTime)
        }
        return session
    }

    /// One untimed sample of the slices in `units`, written straight into its block buffer.
    private static func sampleBuffer(_ units: [NALUnit], format: CMVideoFormatDescription)
        throws(StreamDecodeFailure) -> CMSampleBuffer
    {
        guard let size = AnnexB.sampleSize(of: units) else { throw .noPicture }
        var block: CMBlockBuffer?
        var status = CMBlockBufferCreateWithMemoryBlock(
            allocator: nil, memoryBlock: nil, blockLength: size, blockAllocator: nil, customBlockSource: nil,
            offsetToData: 0, dataLength: size, flags: kCMBlockBufferAssureMemoryNowFlag,
            blockBufferOut: &block)
        var data: UnsafeMutablePointer<CChar>?
        if status == noErr, let block {
            status = CMBlockBufferGetDataPointer(
                block, atOffset: 0, lengthAtOffsetOut: nil, totalLengthOut: nil, dataPointerOut: &data)
        }
        guard status == noErr, let block, let data else {
            throw .sampleBuffer(status == noErr ? kCMBlockBufferBadPointerParameterErr : status)
        }
        AnnexB.writeSample(of: units, into: UnsafeMutableRawBufferPointer(start: data, count: size))
        var sample: CMSampleBuffer?
        status = CMSampleBufferCreateReady(
            allocator: nil, dataBuffer: block, formatDescription: format, sampleCount: 1,
            sampleTimingEntryCount: 0, sampleTimingArray: nil, sampleSizeEntryCount: 1,
            sampleSizeArray: [size], sampleBufferOut: &sample)
        guard status == noErr, let sample else { throw .sampleBuffer(status) }
        return sample
    }
}

/// What the output handler saw, handed back across the VideoToolbox thread.
private final class DecodeOutput: Sendable {
    /// nil until the handler runs.
    let result = Mutex<(OSStatus, Handed)?>(nil)
}

/// The decoded image, moved once from the handler's thread to the caller's. CVPixelBuffer isn't
/// marked Sendable, but it is a thread-safe, reference-counted CF object, and nothing touches
/// it until `decode` takes it after the handler is done.
private struct Handed: @unchecked Sendable {
    let image: CVImageBuffer?
}
