/// Whether a connection to the askpass bridge may ask a question.
public protocol AskpassPeerCheck: Sendable {
    func accepts(_ socket: Int32) -> Bool
}

#if os(macOS)
    public import Foundation

    /// The bridge's peer check: the connection must come from this user's `helper`, run by `ssh`
    /// (`/usr/bin/ssh`) that is the master or descends from it (a jump host's ssh). A
    /// ProxyCommand program, or anything else, is refused.
    ///
    /// - The uid is the socket's peer's (`getpeereid`).
    /// - The executable is read through the peer's audit token (`LOCAL_PEERTOKEN`,
    ///   `proc_pidpath_audittoken`), which fails if the pid has since been reused.
    /// - The parent is walked up at most 8 steps to the master's pid.
    /// - `helper` is kept resolved (`realpath`), as the kernel reports it.
    public struct AskpassPeer: AskpassPeerCheck {
        public let helper: String
        public let ssh: String
        /// The master's pid, once it runs.
        public let masterPID: @Sendable () -> pid_t?

        public init(
            helper: String, ssh: String = SSHCommand.executable, masterPID: @escaping @Sendable () -> pid_t?
        ) {
            self.ssh = ssh
            let resolved = realpath(helper, nil)
            defer { free(resolved) }
            self.helper = resolved.map { String(cString: $0) } ?? helper
            self.masterPID = masterPID
        }

        static let ancestorLimit = 8

        public func accepts(_ socket: Int32) -> Bool {
            var uid: uid_t = 0
            var gid: gid_t = 0
            guard getpeereid(socket, &uid, &gid) == 0, uid == getuid() else { return false }
            var token = audit_token_t()
            var length = socklen_t(MemoryLayout<audit_token_t>.size)
            guard getsockopt(socket, SOL_LOCAL, LOCAL_PEERTOKEN, &token, &length) == 0,
                Self.path(of: &token) == helper, let master = masterPID()
            else { return false }
            // The audit token's sixth word is the pid.
            let pid = pid_t(bitPattern: token.val.5)
            guard let parent = Self.parent(of: pid), Self.path(of: parent) == ssh else { return false }
            var ancestor = parent
            for _ in 0..<Self.ancestorLimit {
                if ancestor == master { return true }
                guard let next = Self.parent(of: ancestor), next > 1 else { return false }
                ancestor = next
            }
            return false
        }

        private static func path(of token: inout audit_token_t) -> String? {
            path { proc_pidpath_audittoken(&token, $0, $1) }
        }

        private static func path(of pid: pid_t) -> String? {
            path { proc_pidpath(pid, $0, $1) }
        }

        /// The path `read` writes into a buffer of `MAXPATHLEN`, or nil when it fails.
        private static func path(_ read: (UnsafeMutableRawPointer?, UInt32) -> Int32) -> String? {
            var buffer = [UInt8](repeating: 0, count: Int(MAXPATHLEN))
            guard buffer.withUnsafeMutableBytes({ read($0.baseAddress, UInt32($0.count)) }) > 0 else {
                return nil
            }
            return String(validating: buffer.prefix { $0 != 0 }, as: UTF8.self)
        }

        private static func parent(of pid: pid_t) -> pid_t? {
            var info = proc_bsdinfo()
            let size = Int32(MemoryLayout<proc_bsdinfo>.size)
            guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size else { return nil }
            return pid_t(info.pbi_ppid)
        }
    }
#endif
