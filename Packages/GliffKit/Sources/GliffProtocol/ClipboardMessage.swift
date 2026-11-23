/// The clipboard messages both ends send. They share fields but have different variant
/// indices in each direction: see `Kind`.
public enum ClipboardMessage: Equatable, Sendable {
    /// The sender's clipboard changed. `serial` names this offer in later requests.
    case offer(serial: UInt32, mimeTypes: [String], files: [ClipboardFile])
    /// Asks for one item of offer `serial`; `id` names the transfer.
    case request(id: UInt32, serial: UInt32, item: ClipboardItem)
    /// A chunk of transfer `id`; its `dataLength` bytes follow as the frame's payload.
    case data(id: UInt32, offset: UInt64, dataLength: UInt32, done: Bool)
    /// Flow control: the receiver has `received` bytes of transfer `id`.
    case ack(id: UInt32, received: UInt64)
    case abort(id: UInt32)

    /// Raw values are upstream's variant names, for errors and the inspector.
    public enum Kind: String, Sendable {
        case offer = "ClipboardOffer"
        case request = "ClipboardRequest"
        case data = "ClipboardData"
        case ack = "ClipboardAck"
        case abort = "ClipboardAbort"

        /// The variant index in `ClientMsg` (upstream `msg.rs`).
        var clientVariant: Int64 {
            switch self {
            case .offer: 8
            case .request: 9
            case .data: 10
            case .ack: 13
            case .abort: 14
            }
        }

        /// The variant index in `ServerMsg`.
        var serverVariant: Int64 {
            switch self {
            case .offer: 5
            case .request: 6
            case .data: 7
            case .ack: 10
            case .abort: 11
            }
        }

        /// A plain switch, not a search: it runs for every server message.
        init?(serverVariant: Int64) {
            switch serverVariant {
            case 5: self = .offer
            case 6: self = .request
            case 7: self = .data
            case 10: self = .ack
            case 11: self = .abort
            default: return nil
            }
        }
    }

    public var kind: Kind {
        switch self {
        case .offer: .offer
        case .request: .request
        case .data: .data
        case .ack: .ack
        case .abort: .abort
        }
    }

    /// Reads the field list of a clipboard message of `kind`.
    init(_ kind: Kind, reader: inout CBORReader) throws {
        self = try FieldReader.read(&reader, type: kind.rawValue) { f in
            switch kind {
            case .offer: .offer(serial: try f.next(), mimeTypes: try f.next(), files: try f.next())
            case .request: .request(id: try f.next(), serial: try f.next(), item: try f.next())
            case .data:
                .data(id: try f.next(), offset: try f.next(), dataLength: try f.next(), done: try f.next())
            case .ack: .ack(id: try f.next(), received: try f.next())
            case .abort: .abort(id: try f.next())
            }
        }
    }

    /// Writes this message as `[variant, [fields…]]`; the index depends on the direction.
    func encode(to w: inout CBORWriter, variant: Int64) {
        switch self {
        case .offer(let serial, let mimeTypes, let files):
            w.variant(variant, fieldCount: 3)
            w.unsigned(UInt64(serial))
            w.array(mimeTypes) { $0.text($1) }
            w.array(files) { $1.encode(to: &$0) }
        case .request(let id, let serial, let item):
            w.variant(variant, fieldCount: 3)
            w.unsigned(UInt64(id))
            w.unsigned(UInt64(serial))
            item.encode(to: &w)
        case .data(let id, let offset, let dataLength, let done):
            w.variant(variant, fieldCount: 4)
            w.unsigned(UInt64(id))
            w.unsigned(offset)
            w.unsigned(UInt64(dataLength))
            w.bool(done)
        case .ack(let id, let received):
            w.variant(variant, fieldCount: 2)
            w.unsigned(UInt64(id))
            w.unsigned(received)
        case .abort(let id):
            w.variant(variant, fieldCount: 1)
            w.unsigned(UInt64(id))
        }
    }
}
