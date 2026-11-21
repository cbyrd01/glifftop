/// An optional protocol feature as a plug-in unit: it is offered in Hello by
/// name, activated when the server echoes that name in HelloAck, and then receives the
/// server message variants it claims, which this build otherwise skips as unknown.
public protocol SessionFeature: Sendable {
    var name: String { get }
    /// Server message variant indices this feature handles.
    var serverVariants: Set<Int64> { get }
    func activate(_ context: FeatureContext) async
    /// One claimed message: its CBOR body (`[variant, fields]`) and payload.
    func receive(variant: Int64, body: [UInt8], payload: [UInt8]) async
}

/// What an active feature can do with the session: send its own client messages.
public struct FeatureContext: Sendable {
    private let sendFrame: @Sendable ([UInt8], [UInt8]) async -> Void

    init(send: @escaping @Sendable (_ body: [UInt8], _ payload: [UInt8]) async -> Void) {
        sendFrame = send
    }

    /// Queues one frame (CBOR body and payload) on the session's writer.
    public func send(body: [UInt8], payload: [UInt8] = []) async {
        await sendFrame(body, payload)
    }
}
