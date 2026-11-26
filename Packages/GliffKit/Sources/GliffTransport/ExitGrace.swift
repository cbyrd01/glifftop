#if os(macOS)
    import Foundation

    /// When a process's output pipes close after it exits. A grandchild may hold them open after
    /// the process is gone, so they don't wait for their end for ever: a second after the exit,
    /// and each second after that, a pipe closes unless a reader running late has left something
    /// in it, bytes or its end. At the last check it closes anyway.
    enum ExitGrace {
        /// The most checks, a second apart.
        static let checks = 10

        /// Whether to close the pipe read through `descriptor` at check number `check` (from 1).
        /// It stays open only while something waits unread in it and nothing was read from it
        /// since the last check: bytes waiting while the reader keeps up are a grandchild's new
        /// output, not the process's.
        static func closes(_ descriptor: Int32, readSinceLastCheck: Bool, check: Int) -> Bool {
            readSinceLastCheck || check >= checks || !waiting(descriptor)
        }

        /// Whether bytes, or the pipe's end, wait unread in `descriptor`; a failed poll can't
        /// tell, so the next check asks again.
        private static func waiting(_ descriptor: Int32) -> Bool {
            var entry = pollfd(fd: descriptor, events: Int16(POLLIN), revents: 0)
            let ready = poll(&entry, 1, 0)
            return ready < 0 || (ready == 1 && entry.revents & Int16(POLLIN | POLLHUP) != 0)
        }
    }
#endif
