import CoreMedia
import CoreVideo
import Synchronization
import VideoToolbox

/// Encodes pictures into H.264 access units shaped like gliff-server's: Annex B with 4-byte
/// start codes, `[SPS, PPS, IDR]` first (SPS without VUI), then one P slice per picture.
public enum H264Encoder {
    public struct Failure: Error, CustomStringConvertible {
        public let description: String
    }

    public static func encode(_ frames: [NV12]) throws -> [AccessUnit] {
        guard let first = frames.first else { return [] }
        let session = try makeSession(width: first.width, height: first.height)
        defer { VTCompressionSessionInvalidate(session) }
        let output = Mutex<[Result<Encoded, Failure>]>([])
        for (index, frame) in frames.enumerated() {
            let options = index == 0 ? [kVTEncodeFrameOptionKey_ForceKeyFrame: true] as CFDictionary : nil
            let status = VTCompressionSessionEncodeFrame(
                session, imageBuffer: try pixelBuffer(frame),
                presentationTimeStamp: CMTime(value: Int64(index), timescale: 60), duration: .invalid,
                frameProperties: options, infoFlagsOut: nil
            ) { status, flags, sample in
                let result = Result { () throws(Failure) in
                    guard !flags.contains(.frameDropped) else {
                        throw Failure(description: "VideoToolbox dropped frame \(index)")
                    }
                    guard status == noErr, let sample else {
                        throw Failure(description: "encode failed: \(status)")
                    }
                    return try Encoded(sample)
                }
                output.withLock { $0.append(result) }
            }
            guard status == noErr else { throw Failure(description: "EncodeFrame: \(status)") }
        }
        VTCompressionSessionCompleteFrames(session, untilPresentationTimeStamp: .invalid)
        let encoded = try output.withLock { results in try results.map { try $0.get() } }
        guard encoded.count == frames.count else {
            throw Failure(description: "\(frames.count) pictures in, \(encoded.count) out")
        }
        return try encoded.enumerated().map { index, frame throws(Failure) in
            guard frame.isKeyframe == (index == 0) else {
                throw Failure(description: "frame \(index) keyframe: \(frame.isKeyframe)")
            }
            guard let parameterSets = frame.parameterSets else { return AccessUnit(units: frame.slices) }
            return AccessUnit(units: [try withoutVUI(parameterSets.sps), parameterSets.pps] + frame.slices)
        }
    }

    private static func makeSession(width: Int, height: Int) throws -> VTCompressionSession {
        var session: VTCompressionSession?
        let status = VTCompressionSessionCreate(
            allocator: nil, width: Int32(width), height: Int32(height), codecType: kCMVideoCodecType_H264,
            encoderSpecification: nil, imageBufferAttributes: nil, compressedDataAllocator: nil,
            outputCallback: nil, refcon: nil, compressionSessionOut: &session)
        guard status == noErr, let session else { throw Failure(description: "session: \(status)") }
        let properties: [CFString: Any] = [
            kVTCompressionPropertyKey_ProfileLevel: kVTProfileLevel_H264_High_AutoLevel,
            kVTCompressionPropertyKey_H264EntropyMode: kVTH264EntropyMode_CABAC,
            kVTCompressionPropertyKey_RealTime: true,
            kVTCompressionPropertyKey_AllowFrameReordering: false,
            kVTCompressionPropertyKey_MaxKeyFrameInterval: 1000,
            kVTCompressionPropertyKey_Quality: 0.95,
        ]
        for (key, value) in properties {
            let status = VTSessionSetProperty(session, key: key, value: value as CFTypeRef)
            guard status == noErr else { throw Failure(description: "\(key): \(status)") }
        }
        return session
    }

    /// A `420v` pixel buffer holding `frame`, row by row (the buffer's rows may be padded).
    private static func pixelBuffer(_ frame: NV12) throws -> CVPixelBuffer {
        var buffer: CVPixelBuffer?
        let attributes = [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary
        let status = CVPixelBufferCreate(
            nil, frame.width, frame.height, kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange, attributes,
            &buffer)
        guard status == kCVReturnSuccess, let buffer else {
            throw Failure(description: "pixel buffer: \(status)")
        }
        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        for (plane, bytes, rows) in [(0, frame.luma, frame.height), (1, frame.chroma, frame.height / 2)] {
            guard let base = CVPixelBufferGetBaseAddressOfPlane(buffer, plane) else {
                throw Failure(description: "no plane \(plane)")
            }
            let stride = CVPixelBufferGetBytesPerRowOfPlane(buffer, plane)
            for row in 0..<rows {
                bytes[row * frame.width..<(row + 1) * frame.width].withUnsafeBytes { source in
                    UnsafeMutableRawBufferPointer(start: base + row * stride, count: source.count)
                        .copyMemory(from: source)
                }
            }
        }
        return buffer
    }

    private static func withoutVUI(_ sps: [UInt8]) throws(Failure) -> [UInt8] {
        do {
            return try SPSRewriter.withoutVUI(sps)
        } catch {
            throw Failure(description: "SPS: \(error)")
        }
    }
}

/// One encoded picture: its slices (VideoToolbox's 4-byte length-prefixed form, split), and
/// for a keyframe the session's parameter sets.
private struct Encoded: Sendable {
    let slices: [[UInt8]]
    let isKeyframe: Bool
    let parameterSets: (sps: [UInt8], pps: [UInt8])?

    init(_ sample: CMSampleBuffer) throws(H264Encoder.Failure) {
        guard let block = sample.dataBuffer, let format = sample.formatDescription else {
            throw .init(description: "empty sample")
        }
        var bytes = [UInt8](repeating: 0, count: CMBlockBufferGetDataLength(block))
        guard
            CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: bytes.count, destination: &bytes)
                == noErr
        else { throw .init(description: "copy failed") }
        var units: [[UInt8]] = []
        var index = 0
        while index + 4 <= bytes.count {
            let length = bytes[index..<index + 4].reduce(0) { $0 << 8 | Int($1) }
            guard index + 4 + length <= bytes.count else { throw .init(description: "bad NAL length") }
            units.append(Array(bytes[index + 4..<index + 4 + length]))
            index += 4 + length
        }
        // Only coded slices: upstream sends no SEI.
        slices = units.filter { $0.first.map { (1...5).contains($0 & 0x1F) } ?? false }
        let attachments =
            CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: false)
            as? [[CFString: Any]]
        isKeyframe = !(attachments?.first?[kCMSampleAttachmentKey_NotSync] as? Bool ?? false)
        parameterSets =
            isKeyframe ? (try Self.parameterSet(format, 0), try Self.parameterSet(format, 1)) : nil
    }

    private static func parameterSet(_ format: CMFormatDescription, _ index: Int) throws(H264Encoder.Failure)
        -> [UInt8]
    {
        var pointer: UnsafePointer<UInt8>?
        var size = 0
        var lengthSize: Int32 = 0
        var count = 0
        let status = CMVideoFormatDescriptionGetH264ParameterSetAtIndex(
            format, parameterSetIndex: index, parameterSetPointerOut: &pointer, parameterSetSizeOut: &size,
            parameterSetCountOut: &count, nalUnitHeaderLengthOut: &lengthSize)
        guard status == noErr, let pointer, lengthSize == 4, count == 2 else {
            throw .init(
                description: "parameter set \(index): \(status), \(count) sets, length size \(lengthSize)")
        }
        return Array(UnsafeBufferPointer(start: pointer, count: size))
    }
}
