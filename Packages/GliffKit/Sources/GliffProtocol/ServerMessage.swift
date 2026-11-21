/// Tells the client how to decode the video that follows.
public struct StreamConfig: Equatable, Sendable {
    public var codec: Codec
    public var chroma: ChromaMode
    /// nil if the server didn't say, or named a pipeline this build doesn't know.
    public var pipeline: VideoPipeline?
    /// Stream size in physical pixels.
    public var width, height, scaleMilli: UInt32
    public var extradata: [UInt8]
    /// The second stream's extradata, for `dual420`.
    public var auxExtradata: [UInt8]?
    public var viewWidth, viewHeight, fpsCap: UInt32

    public init(
        codec: Codec, chroma: ChromaMode, pipeline: VideoPipeline?, width: UInt32, height: UInt32,
        scaleMilli: UInt32, extradata: [UInt8], auxExtradata: [UInt8]?, viewWidth: UInt32,
        viewHeight: UInt32, fpsCap: UInt32
    ) {
        (self.codec, self.chroma, self.pipeline) = (codec, chroma, pipeline)
        (self.width, self.height, self.scaleMilli) = (width, height, scaleMilli)
        (self.extradata, self.auxExtradata) = (extradata, auxExtradata)
        (self.viewWidth, self.viewHeight, self.fpsCap) = (viewWidth, viewHeight, fpsCap)
    }
}

/// A video frame's metadata. Its `dataLength` + `auxLength` bytes follow as the payload.
public struct VideoFrameHeader: Equatable, Sendable {
    public var frameID: UInt64
    public var ptsMicroseconds: UInt64
    public var isKeyframe: Bool
    public var damage: [Rect]
    public var dataLength: UInt32
    public var auxLength: UInt32

    public init(
        frameID: UInt64, ptsMicroseconds: UInt64, isKeyframe: Bool, damage: [Rect], dataLength: UInt32,
        auxLength: UInt32
    ) {
        (self.frameID, self.ptsMicroseconds, self.isKeyframe) = (frameID, ptsMicroseconds, isKeyframe)
        (self.damage, self.dataLength, self.auxLength) = (damage, dataLength, auxLength)
    }
}

/// A new cursor image; its `argbLength` bytes follow as the payload.
public struct CursorShape: Equatable, Sendable {
    public var id, width, height: UInt32
    public var hotX, hotY: Int32
    public var argbLength: UInt32

    public init(id: UInt32, width: UInt32, height: UInt32, hotX: Int32, hotY: Int32, argbLength: UInt32) {
        (self.id, self.width, self.height) = (id, width, height)
        (self.hotX, self.hotY, self.argbLength) = (hotX, hotY, argbLength)
    }
}

/// A message from gliff-server (upstream `ServerMsg`). Case order is not the wire order;
/// the variant indices are in `decodeFields`, and the clipboard ones in `ClipboardMessage.Kind`.
public enum ServerMessage: Equatable, Sendable {
    case helloAck(version: UInt16, session: SessionInfo, outputs: [OutputInfo], features: [String])
    case streamConfig(StreamConfig)
    case videoFrame(VideoFrameHeader)
    case cursorShape(CursorShape)
    case cursorPosition(x: Double, y: Double, shapeID: UInt32, visible: Bool)
    case clipboard(ClipboardMessage)
    case pong(t: UInt64, serverNowMilliseconds: UInt64)
    /// `version` is the server's protocol version, sent with a version mismatch.
    case error(code: UInt16, message: String, version: UInt16?)
    case ping(t: UInt64)
    /// A message this build doesn't know. Skip it, and the payload its frame header declares.
    case unknown(variant: Int64)

    /// Decodes one frame body: `[variant, [fields…]]`. An unknown variant returns `.unknown`
    /// without reading its fields, as upstream's transport does. Bytes after the message are
    /// ignored, as upstream does.
    public static func decode(_ body: [UInt8]) throws -> ServerMessage {
        var reader = CBORReader(body)
        return try FieldReader.readVariant(&reader) { variant, fields in
            try decodeFields(variant: variant, reader: &fields)
        }
    }

    private static func decodeFields(variant: Int64, reader: inout CBORReader) throws -> ServerMessage {
        if let kind = ClipboardMessage.Kind(serverVariant: variant) {
            return .clipboard(try ClipboardMessage(kind, reader: &reader))
        }
        return switch variant {
        case 0:
            try FieldReader.read(&reader, type: "HelloAck") { f in
                .helloAck(
                    version: try f.next(), session: try f.next(), outputs: try f.next(),
                    features: try f.next())
            }
        case 1: .streamConfig(try StreamConfig(cbor: &reader))
        case 2: .videoFrame(try VideoFrameHeader(cbor: &reader))
        case 3: .cursorShape(try CursorShape(cbor: &reader))
        case 4:
            try FieldReader.read(&reader, type: "CursorPos") { f in
                .cursorPosition(
                    x: try f.next(), y: try f.next(), shapeID: try f.next(), visible: try f.next())
            }
        case 8:
            try FieldReader.read(&reader, type: "Pong") { f in
                .pong(t: try f.next(), serverNowMilliseconds: try f.next())
            }
        case 9:
            try FieldReader.read(&reader, type: "Error") { f in
                .error(code: try f.next(), message: try f.next(), version: try f.optional())
            }
        case 12: try FieldReader.read(&reader, type: "Ping") { f in .ping(t: try f.next()) }
        default: .unknown(variant: variant)
        }
    }
}

extension StreamConfig: CBORDecodable {
    init(cbor reader: inout CBORReader) throws {
        self = try FieldReader.read(&reader, type: "StreamConfig") { f in
            StreamConfig(
                codec: try f.next(), chroma: try f.next(), pipeline: try f.optionalLenient(),
                width: try f.next(), height: try f.next(), scaleMilli: try f.next(),
                extradata: try f.next { try $0.byteString() },
                auxExtradata: try f.optional { try $0.byteString() },
                viewWidth: try f.next(), viewHeight: try f.next(), fpsCap: try f.next())
        }
    }
}

extension VideoFrameHeader: CBORDecodable {
    init(cbor reader: inout CBORReader) throws {
        self = try FieldReader.read(&reader, type: "VideoFrame") { f in
            VideoFrameHeader(
                frameID: try f.next(), ptsMicroseconds: try f.next(), isKeyframe: try f.next(),
                damage: try f.next(), dataLength: try f.next(), auxLength: try f.next())
        }
    }
}

extension CursorShape: CBORDecodable {
    init(cbor reader: inout CBORReader) throws {
        self = try FieldReader.read(&reader, type: "CursorShape") { f in
            CursorShape(
                id: try f.next(), width: try f.next(), height: try f.next(),
                hotX: try f.next(), hotY: try f.next(), argbLength: try f.next())
        }
    }
}
