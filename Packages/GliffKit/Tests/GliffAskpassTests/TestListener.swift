import Foundation
import GliffAskpass
import Synchronization

/// A Unix socket listener in a private temporary directory, for playing the app's side.
final class TestListener: Sendable {
    let path: String
    private let directory: String
    private let socket: Int32
    private let closed = Mutex(false)

    struct Failed: Error {}

    init() throws {
        directory = "/tmp/gat-\(UUID().uuidString.prefix(8))"
        try FileManager.default.createDirectory(
            atPath: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        path = directory + "/b"
        guard var address = AskpassSocket.address(path), let socket = AskpassSocket.make() else {
            throw Failed()
        }
        self.socket = socket
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(socket, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard bound == 0, listen(socket, 4) == 0 else { throw Failed() }
    }

    func accept() -> Int32? {
        let client = Darwin.accept(socket, nil, nil)
        return client >= 0 ? client : nil
    }

    /// Stops listening (a blocked `accept` returns) and removes the directory.
    func close() {
        guard
            !closed.withLock({
                defer { $0 = true }
                return $0
            })
        else { return }
        shutdown(socket, SHUT_RDWR)
        Darwin.close(socket)
        try? FileManager.default.removeItem(atPath: directory)
    }

    static func read(_ socket: Int32, count: Int) -> [UInt8]? {
        var bytes = [UInt8](repeating: 0, count: count)
        return bytes.withUnsafeMutableBytes { AskpassSocket.read(socket, into: $0) } ? bytes : nil
    }

    static func write(_ socket: Int32, _ bytes: [UInt8]) {
        _ = bytes.withUnsafeBytes { AskpassSocket.write(socket, $0) }
    }
}
