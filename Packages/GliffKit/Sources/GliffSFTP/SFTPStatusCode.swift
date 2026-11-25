/// A STATUS reply's code (draft-ietf-secsh-filexfer-02, section 7). Its message is host text
/// and isn't kept.
public enum SFTPStatusCode: Equatable, Sendable {
    case ok, endOfFile, noSuchFile, permissionDenied, failure, badMessage, noConnection, connectionLost
    case unsupported
    case other(UInt32)

    public init(_ raw: UInt32) {
        self =
            switch raw {
            case 0: .ok
            case 1: .endOfFile
            case 2: .noSuchFile
            case 3: .permissionDenied
            case 4: .failure
            case 5: .badMessage
            case 6: .noConnection
            case 7: .connectionLost
            case 8: .unsupported
            default: .other(raw)
            }
    }
}
