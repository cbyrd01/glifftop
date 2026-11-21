/// One frame off the wire: a CBOR message body and the raw payload bytes that follow it.
public struct Frame: Equatable, Sendable {
    public var body: [UInt8]
    public var payload: [UInt8]

    public init(body: [UInt8], payload: [UInt8] = []) {
        self.body = body
        self.payload = payload
    }

    /// The frame as sent: header, body, payload. Throws `bodyTooLarge`, or `payloadTooLarge`
    /// for a payload over `FrameHeader.maxPayload` (the peer reads it as one section).
    public static func encode(body: [UInt8], payload: [UInt8] = []) throws(ProtocolError) -> [UInt8] {
        let header = try FrameHeader(
            bodyLength: UInt32(clamping: body.count), payloadLength: UInt32(clamping: payload.count))
        guard header.payloadLength <= FrameHeader.maxPayload else {
            throw .payloadTooLarge(header.payloadLength)
        }
        var bytes = header.encoded
        bytes.reserveCapacity(FrameHeader.size + body.count + payload.count)
        bytes += body
        bytes += payload
        return bytes
    }
}

/// Splits a byte stream into frames, however the stream was chunked.
///
/// - The header is validated as soon as its 8 bytes arrive, so a peer that isn't speaking
///   the protocol (a login banner) fails before anything large is buffered.
/// - Consumed bytes are dropped only once they are at least half the buffer, so a large
///   frame arriving in many small reads costs linear copying, not quadratic.
public struct FrameParser: Sendable {
    private var buffer: [UInt8] = []
    /// Where the unconsumed bytes start in `buffer`.
    private var readIndex = 0
    /// The header of the frame being assembled, once read.
    private var header: FrameHeader?
    public private(set) var framesParsed = 0

    public init() {}

    /// Bytes received but not yet returned as part of a frame.
    public var bufferedByteCount: Int { buffer.count - readIndex }

    public mutating func append(_ bytes: some Collection<UInt8>) {
        buffer.append(contentsOf: bytes)
    }

    /// The next complete frame, or nil until more bytes arrive. After a throw the stream is
    /// unusable: the caller ends the session.
    public mutating func next() throws(ProtocolError) -> Frame? {
        // Not `header ?? readHeader()`: `??` rethrows as `any Error`.
        if header == nil { header = try readHeader() }
        guard let header else { return nil }
        let bodyLength = Int(header.bodyLength)
        let total = bodyLength + Int(header.payloadLength)
        guard bufferedByteCount >= total else { return nil }

        let bodyEnd = readIndex + bodyLength
        let frame = Frame(
            body: Array(buffer[readIndex..<bodyEnd]),
            payload: Array(buffer[bodyEnd..<(readIndex + total)]))
        readIndex += total
        self.header = nil
        framesParsed += 1
        compact()
        return frame
    }

    /// Consumes and validates the next header once its 8 bytes are here, and reserves room
    /// for the whole frame so a large one doesn't grow the buffer by repeated doubling.
    private mutating func readHeader() throws(ProtocolError) -> FrameHeader? {
        guard bufferedByteCount >= FrameHeader.size else { return nil }
        let header = try FrameHeader(decoding: buffer[readIndex...])
        readIndex += FrameHeader.size
        buffer.reserveCapacity(readIndex + Int(header.bodyLength) + Int(header.payloadLength))
        return header
    }

    private mutating func compact() {
        if readIndex == buffer.count {
            buffer.removeAll(keepingCapacity: true)
            readIndex = 0
        } else if readIndex >= buffer.count / 2 {
            buffer.removeFirst(readIndex)
            readIndex = 0
        }
    }
}
