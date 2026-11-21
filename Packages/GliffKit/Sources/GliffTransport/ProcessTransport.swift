#if os(macOS)
    public import Foundation

    /// Runs a program and speaks to it over its stdin and stdout. stderr is kept (its last
    /// 16 KiB) to say why the program failed. Tests run `tools/fake-server` with it.
    public struct ProcessTransport: Transport {
        let executable: URL
        let arguments: [String]
        let classify: @Sendable (Int32, String) -> ConnectFailure

        public init(
            executable: URL, arguments: [String],
            classify: @escaping @Sendable (Int32, String) -> ConnectFailure = SSHErrorClassifier.classify
        ) {
            self.executable = executable
            self.arguments = arguments
            self.classify = classify
        }

        public func connect() async throws(TransportError) -> any ByteConnection {
            try ProcessConnection.launch(executable: executable, arguments: arguments, classify: classify)
        }
    }

    /// The system ssh (`/usr/bin/ssh`) running `gliff-server --stdio` on the target.
    public struct SystemSSHTransport: Transport {
        let process: ProcessTransport

        public init(command: SSHCommand) {
            process = ProcessTransport(
                executable: URL(filePath: SSHCommand.executable), arguments: command.arguments)
        }

        public func connect() async throws(TransportError) -> any ByteConnection {
            try await process.connect()
        }
    }
#endif
