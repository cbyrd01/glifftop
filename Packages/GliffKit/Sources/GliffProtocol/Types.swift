// Value types shared by client and server messages (upstream `msg.rs` and `clipboard.rs`).
// Raw values and field order are the wire format: never reorder.

public enum Codec: Int64, Sendable, WireEnum {
    case rawBgra = 0
    case h264 = 1
    case h265 = 2
    case av1 = 3
}

/// Which pipeline encodes on the server; reported for the client's stats.
public enum VideoPipeline: Int64, Sendable, WireEnum {
    case gpu = 0
    case cpu = 1
}

public enum ChromaMode: Int64, Sendable, WireEnum {
    case native444 = 0
    case dual420 = 1
    case single420 = 2
}

public enum Axis: Int64, Sendable, WireEnum {
    case vertical = 0
    case horizontal = 1
}

/// A damaged region of the frame, in stream pixels.
public struct Rect: Equatable, Sendable {
    public var x, y, width, height: Int32

    public init(x: Int32, y: Int32, width: Int32, height: Int32) {
        (self.x, self.y, self.width, self.height) = (x, y, width, height)
    }
}

public struct ClientCaps: Equatable, Sendable {
    public var codecs: [Codec]
    public var maxWidth, maxHeight: UInt32
    /// Chroma modes the client can decode, preferred first.
    public var chroma: [ChromaMode]
    public var features: [String]

    public init(
        codecs: [Codec], maxWidth: UInt32, maxHeight: UInt32, chroma: [ChromaMode], features: [String]
    ) {
        (self.codecs, self.maxWidth, self.maxHeight) = (codecs, maxWidth, maxHeight)
        (self.chroma, self.features) = (chroma, features)
    }
}

public struct OutputInfo: Equatable, Sendable {
    public var name: String
    public var width, height, scaleMilli: UInt32

    public init(name: String, width: UInt32, height: UInt32, scaleMilli: UInt32) {
        (self.name, self.width, self.height, self.scaleMilli) = (name, width, height, scaleMilli)
    }
}

public struct SessionInfo: Equatable, Sendable {
    public var headless: Bool
    public var output: String

    public init(headless: Bool, output: String) {
        (self.headless, self.output) = (headless, output)
    }
}

public struct ClipboardFile: Equatable, Sendable {
    /// Relative path within the offer; may contain any Unicode.
    public var path: String
    public var size: UInt64
    public var isDirectory: Bool

    public init(path: String, size: UInt64, isDirectory: Bool) {
        (self.path, self.size, self.isDirectory) = (path, size, isDirectory)
    }
}

public enum ClipboardItem: Equatable, Sendable {
    case mime(String)
    /// An index into the offer's `files`.
    case file(index: UInt32)
}

// MARK: - Decoding

extension Rect: CBORDecodable {
    init(cbor reader: inout CBORReader) throws {
        self = try FieldReader.read(&reader, type: "Rect") { f in
            Rect(x: try f.next(), y: try f.next(), width: try f.next(), height: try f.next())
        }
    }
}

extension OutputInfo: CBORDecodable {
    init(cbor reader: inout CBORReader) throws {
        self = try FieldReader.read(&reader, type: "OutputInfo") { f in
            OutputInfo(
                name: try f.next(), width: try f.next(), height: try f.next(), scaleMilli: try f.next())
        }
    }
}

extension SessionInfo: CBORDecodable {
    init(cbor reader: inout CBORReader) throws {
        self = try FieldReader.read(&reader, type: "SessionInfo") { f in
            SessionInfo(headless: try f.next(), output: try f.next())
        }
    }
}

extension ClipboardFile: CBORDecodable {
    init(cbor reader: inout CBORReader) throws {
        self = try FieldReader.read(&reader, type: "ClipboardFile") { f in
            ClipboardFile(path: try f.next(), size: try f.next(), isDirectory: try f.next())
        }
    }
}

extension ClipboardItem: CBORDecodable {
    /// `[variant, [field]]`, like a message.
    init(cbor reader: inout CBORReader) throws {
        self = try FieldReader.readVariant(&reader) { variant, fields in
            try FieldReader.read(&fields, type: "ClipboardItem") { f in
                switch variant {
                case 0: .mime(try f.next())
                case 1: .file(index: try f.next())
                default: throw ProtocolError.unknownEnumValue(type: "ClipboardItem", value: variant)
                }
            }
        }
    }
}

// MARK: - Encoding

extension ClientCaps {
    func encode(to w: inout CBORWriter) {
        w.arrayHeader(count: 5)
        w.array(codecs) { $0.wireEnum($1) }
        w.unsigned(UInt64(maxWidth))
        w.unsigned(UInt64(maxHeight))
        w.array(chroma) { $0.wireEnum($1) }
        w.array(features) { $0.text($1) }
    }
}

extension ClipboardFile {
    func encode(to w: inout CBORWriter) {
        w.arrayHeader(count: 3)
        w.text(path)
        w.unsigned(size)
        w.bool(isDirectory)
    }
}

extension ClipboardItem {
    func encode(to w: inout CBORWriter) {
        switch self {
        case .mime(let type):
            w.variant(0, fieldCount: 1)
            w.text(type)
        case .file(let index):
            w.variant(1, fieldCount: 1)
            w.unsigned(UInt64(index))
        }
    }
}
