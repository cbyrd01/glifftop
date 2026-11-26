import Foundation
import GliffTransport
import Synchronization

/// The watcher's channel in HostPorts' tests: it never speaks unless told to, and reads its
/// run's nonce from its command.
final class PortsChannel: ByteConnection {
    let command: String
    let incoming: AsyncThrowingStream<[UInt8], any Error>
    private let continuation: AsyncThrowingStream<[UInt8], any Error>.Continuation
    private let closed = Mutex(false)
    private let closing = Mutex((held: false, started: false, waiter: CheckedContinuation<Void, Never>?.none))

    init(command: String) {
        self.command = command
        (incoming, continuation) = AsyncThrowingStream.makeStream()
    }

    /// The nonce the command passes the script, unquoted.
    var nonce: String {
        let words = command.split(separator: " ")
        return words[words.count - 2].trimmingCharacters(in: ["'"])
    }

    var isClosed: Bool { closed.withLock { $0 } }

    var closeStarted: Bool { closing.withLock { $0.started } }

    func write(_ bytes: [UInt8]) async throws(TransportError) { throw .writeFailed("not written to") }

    /// A close from now on waits for `releaseClose()`.
    func holdClose() { closing.withLock { $0.held = true } }

    func releaseClose() {
        let waiter = closing.withLock { state in
            state.held = false
            defer { state.waiter = nil }
            return state.waiter
        }
        waiter?.resume()
    }

    func close() async {
        await withCheckedContinuation { (waiter: CheckedContinuation<Void, Never>) in
            let held = closing.withLock { state in
                state.started = true
                if state.held { state.waiter = waiter }
                return state.held
            }
            if !held { waiter.resume() }
        }
        closed.withLock { $0 = true }
        continuation.finish()
    }

    /// A frame of `ports`, each on 0.0.0.0 (those in `lan` on 192.168.1.5 only, those in
    /// `loopback` on 127.0.0.1 only) under uid 1000 and named when a name is given.
    func send(_ ports: [(Int, String?)], lan: Set<Int> = [], loopback: Set<Int> = []) {
        var rows: [String] = []
        var names: [String] = []
        for (port, name) in ports {
            let (hexAddress, address) =
                switch port {
                case _ where lan.contains(port): ("0501A8C0", "192.168.1.5")
                case _ where loopback.contains(port): ("0100007F", "127.0.0.1")
                default: ("00000000", "0.0.0.0")
                }
            rows.append("P \(hexAddress):\(hex(port)) 1000")
            if let name {
                names.append("N LISTEN   \(address):\(port) 0.0.0.0:* users:((\"\(name)\",pid=7,fd=3))")
            }
        }
        send(PortListParserTests.frame(rows + names, nonce: nonce))
    }

    /// The script's line for a host without `/proc/net/tcp`.
    func sendNone() { send(PortListParserTests.frame([], header: "none", nonce: nonce)) }

    func send(lines: [String]) { send(lines.joined(separator: "\n") + "\n") }

    func send(_ text: String) { continuation.yield(Array(text.utf8)) }

    /// The script exits.
    func end() { continuation.finish() }

    /// The channel fails, as ssh reports it.
    func fail(_ error: TransportError) { continuation.finish(throwing: error) }

    private func hex(_ port: Int) -> String { String(format: "%04X", port) }
}
