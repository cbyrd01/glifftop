public import Foundation

/// The few POSIX socket calls the helper and the bridge share. Writes never raise SIGPIPE.
public enum AskpassSocket {
    /// `path` as a Unix socket address, or nil when it is too long for one.
    public static func address(_ path: String) -> sockaddr_un? {
        var address = sockaddr_un()
        let bytes = Array(path.utf8)
        guard !bytes.isEmpty, bytes.count < MemoryLayout.size(ofValue: address.sun_path) else { return nil }
        address.sun_family = sa_family_t(AF_UNIX)
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        withUnsafeMutableBytes(of: &address.sun_path) { raw in
            for (index, byte) in bytes.enumerated() { raw[index] = byte }
        }
        return address
    }

    /// A stream socket with SIGPIPE off, or nil.
    public static func make() -> Int32? {
        let socket = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard socket >= 0 else { return nil }
        var on: Int32 = 1
        setsockopt(socket, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
        return socket
    }

    /// A socket connected to `path`, or nil.
    public static func connect(to path: String) -> Int32? {
        guard var address = address(path), let socket = make() else { return nil }
        let connected = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(socket, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard connected == 0 else {
            close(socket)
            return nil
        }
        return socket
    }

    /// Fills `buffer` from `socket`; false on an error or an end first.
    public static func read(_ socket: Int32, into buffer: UnsafeMutableRawBufferPointer) -> Bool {
        guard let base = buffer.baseAddress else { return true }
        var done = 0
        while done < buffer.count {
            let got = Darwin.read(socket, base + done, buffer.count - done)
            if got < 0, errno == EINTR { continue }
            guard got > 0 else { return false }
            done += got
        }
        return true
    }

    /// Writes all of `bytes` to `descriptor`; false on an error.
    public static func write(_ descriptor: Int32, _ bytes: UnsafeRawBufferPointer) -> Bool {
        guard let base = bytes.baseAddress else { return true }
        var done = 0
        while done < bytes.count {
            let wrote = Darwin.write(descriptor, base + done, bytes.count - done)
            if wrote < 0, errno == EINTR { continue }
            guard wrote > 0 else { return false }
            done += wrote
        }
        return true
    }
}
