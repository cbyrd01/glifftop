extension ServerMessage {
    /// The payload sections this message reads after its body, in order: `[]` for none, nil
    /// for an unknown message (its payload is skipped whatever its size).
    public var declaredPayloads: [UInt32]? {
        switch self {
        case .videoFrame(let header): [header.dataLength, header.auxLength]
        // A malformed shape is ignored and its payload skipped (upstream `read_cursor`).
        case .cursorShape(let shape): shape.payloadFits ? [shape.argbLength] : []
        case .clipboard(.data(_, _, let dataLength, _)): [dataLength]
        case .unknown: nil
        case .helloAck, .streamConfig, .cursorPosition, .clipboard, .pong, .error, .ping: []
        }
    }

    /// Checks the declared payload sections against the `carried` bytes of the frame, as
    /// upstream `read_payload` does: each section at most `FrameHeader.maxPayload`
    /// (`payloadTooLarge`), and together no more than the frame carries (`payloadOverrun`).
    /// Carrying more than declared is fine; the rest is skipped.
    public func checkPayload(carried: Int) throws(ProtocolError) {
        guard let sections = declaredPayloads else { return }
        if let over = sections.first(where: { $0 > FrameHeader.maxPayload }) {
            throw .payloadTooLarge(over)
        }
        let declared = sections.reduce(UInt64(0)) { $0 + UInt64($1) }
        guard declared <= UInt64(carried) else {
            throw .payloadOverrun(declared: declared, carried: UInt64(carried))
        }
    }
}

extension CursorShape {
    /// Largest cursor width or height upstream's client accepts (`net.rs` `MAX_CURSOR`).
    public static let maxSide: UInt32 = 1024

    /// Whether the payload is exactly the tightly packed pixels of a shape of an accepted
    /// size (upstream `cursor_payload_fits`).
    public var payloadFits: Bool {
        (1...Self.maxSide).contains(width) && (1...Self.maxSide).contains(height)
            && UInt64(argbLength) == UInt64(width) * UInt64(height) * 4
    }
}
