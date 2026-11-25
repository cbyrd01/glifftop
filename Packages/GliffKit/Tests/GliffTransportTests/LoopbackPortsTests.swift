#if os(macOS)
    import Foundation
    import Testing

    @testable import GliffTransport

    /// The loopback check against real sockets: a port another socket holds on 127.0.0.1, on
    /// ::1 or on the wildcard address is taken; a free one is free. A port a test lets go of
    /// can be taken at once by another process on this Mac (as a listener's port, or a
    /// connection's), so a test that needs a port to stay free tries a few.
    @Suite(.serialized) struct LoopbackPortsTests {
        static func onceInFew(_ attempt: () throws -> Bool) rethrows -> Bool {
            try (0..<5).contains { _ in try attempt() }
        }

        @Test func aFreePortIsFree() throws {
            let free = try Self.onceInFew {
                let port = try #require(LoopbackPorts.pick())
                return LoopbackPorts.check(port) != .taken
            }
            #expect(free)
        }

        @Test func aPortHeldOn127IsTaken() throws {
            let held = try HeldPort(address: "127.0.0.1")
            defer { held.close() }
            #expect(LoopbackPorts.check(held.port) == .taken)
        }

        @Test func aPortHeldOnIPv6LoopbackIsTaken() throws {
            let held = try HeldPort(address: "::1")
            defer { held.close() }
            #expect(LoopbackPorts.check(held.port) == .taken)
        }

        /// A Mac server on `*:P`, without SO_REUSEADDR: ssh's bind of 127.0.0.1:P would shadow it.
        @Test func aPortHeldOnTheWildcardIsTaken() throws {
            let held = try HeldPort(address: "0.0.0.0")
            defer { held.close() }
            #expect(LoopbackPorts.check(held.port) == .taken)
        }

        @Test func aPortHeldOnTheIPv6WildcardIsTaken() throws {
            let held = try HeldPort(address: "::")
            defer { held.close() }
            #expect(LoopbackPorts.check(held.port) == .taken)
        }

        /// A port whose listener is gone, with an accepted connection it closed first left in
        /// TIME_WAIT, is free: ssh, with `SO_REUSEADDR`, can bind it.
        @Test func aPortInTimeWaitIsFree() throws {
            let free = try Self.onceInFew {
                let held = try HeldPort()
                let client = Self.connect(port: held.port)
                let accepted = client == nil ? -1 : accept(held.socket, nil, nil)
                // The accepted side closes first, so the port is left in TIME_WAIT.
                for descriptor in [accepted, client ?? -1] where descriptor >= 0 { Darwin.close(descriptor) }
                held.close()
                return accepted >= 0 && LoopbackPorts.check(held.port) == .free
            }
            #expect(free)
        }

        /// A listener whose backlog is full drops a new connection's SYN: the check doesn't wait
        /// for a connect that never comes, and calls the port taken.
        @Test func aFullBacklogIsTakenQuickly() throws {
            let held = try HeldPort()
            defer { held.close() }
            var clients: [Int32] = []
            defer { for client in clients { Darwin.close(client) } }
            for _ in 0..<12 { clients.append(Self.connect(port: held.port, waiting: false)) }
            let start = ContinuousClock.now
            #expect(LoopbackPorts.check(held.port) == .taken)
            #expect(ContinuousClock.now - start < .seconds(2))
        }

        /// A TCP socket connected to 127.0.0.1:`port`, nil when refused; without `waiting`, one
        /// whose connect was only started, whatever came of it.
        static func connect(port: Int) -> Int32? {
            let descriptor = connect(port: port, waiting: true)
            return descriptor >= 0 ? descriptor : nil
        }

        static func connect(port: Int, waiting: Bool) -> Int32 {
            let descriptor = socket(AF_INET, SOCK_STREAM, 0)
            if !waiting { _ = fcntl(descriptor, F_SETFL, fcntl(descriptor, F_GETFL) | O_NONBLOCK) }
            var address = sockaddr_in()
            address.sin_family = sa_family_t(AF_INET)
            address.sin_port = in_port_t(UInt16(port).bigEndian)
            address.sin_addr.s_addr = inet_addr("127.0.0.1")
            let connected = withUnsafePointer(to: &address) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    Darwin.connect(descriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) == 0
                }
            }
            guard connected || !waiting else {
                Darwin.close(descriptor)
                return -1
            }
            return descriptor
        }

        @Test func pickGivesAFreePort() throws {
            let free = try Self.onceInFew {
                let port = try #require(LoopbackPorts.pick())
                #expect((1024...65535).contains(port))
                let held = try? HeldPort(address: "127.0.0.1", port: port)
                held?.close()
                return held != nil
            }
            #expect(free)
        }

        @Test func checkLeavesThePortFree() throws {
            let free = try Self.onceInFew {
                let port = try #require(LoopbackPorts.pick())
                _ = LoopbackPorts.check(port)
                let held = try? HeldPort(address: "127.0.0.1", port: port)
                held?.close()
                return held != nil
            }
            #expect(free)
        }
    }

#endif
