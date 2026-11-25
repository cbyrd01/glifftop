import Foundation

/// A password, passphrase or code, in memory of its own that is cleared (`memset_s`) when the
/// secret goes. It can't be copied, printed, compared or encoded: its bytes are lent only to
/// `withBytes`, to be written where they go.
public struct SignInSecret: ~Copyable, @unchecked Sendable {
    private let buffer: UnsafeMutableRawBufferPointer

    /// Copies `text`'s UTF-8 straight into the secret's memory.
    public init(copying text: String) {
        buffer = .allocate(byteCount: text.utf8.count, alignment: 1)
        buffer.copyBytes(from: text.utf8)
    }

    /// Copies `bytes` into the secret's memory; the caller clears its own copy.
    public init(bytes: [UInt8]) {
        buffer = .allocate(byteCount: bytes.count, alignment: 1)
        buffer.copyBytes(from: bytes)
    }

    public var count: Int { buffer.count }

    public borrowing func withBytes<R>(_ body: (UnsafeRawBufferPointer) throws -> R) rethrows -> R {
        try body(UnsafeRawBufferPointer(buffer))
    }

    deinit {
        if let base = buffer.baseAddress { memset_s(base, buffer.count, 0, buffer.count) }
        buffer.deallocate()
    }
}
