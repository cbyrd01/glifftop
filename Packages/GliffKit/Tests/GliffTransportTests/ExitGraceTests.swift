#if os(macOS)
    import Foundation
    import Testing

    @testable import GliffTransport

    /// When a process's output pipes close after it exits: once nothing waits in them, so a
    /// reader running late still gets every byte, and a grandchild holding them open doesn't
    /// keep the output from ending.
    @Suite(.timeLimit(.minutes(1))) struct ExitGraceTests {
        /// A pipe holding `bytes`, and its end too when `ended`.
        private func pipe(_ bytes: String = "", ended: Bool = false) throws -> Pipe {
            let pipe = Pipe()
            if !bytes.isEmpty { pipe.fileHandleForWriting.write(Data(bytes.utf8)) }
            if ended { try pipe.fileHandleForWriting.close() }
            return pipe
        }

        /// The reader is late: nothing read since the last check, the bytes still in the pipe.
        @Test func aPipeWithBytesWaitingStaysOpen() throws {
            let full = try pipe("omarchy")
            #expect(
                !ExitGrace.closes(
                    full.fileHandleForReading.fileDescriptor, readSinceLastCheck: false, check: 1))
        }

        /// An end no reader has seen yet waits too.
        @Test func aPipeWithItsEndWaitingStaysOpen() throws {
            let ended = try pipe(ended: true)
            #expect(
                !ExitGrace.closes(
                    ended.fileHandleForReading.fileDescriptor, readSinceLastCheck: false, check: 1))
        }

        /// A grandchild holds it, quiet.
        @Test func aQuietPipeCloses() throws {
            let empty = try pipe()
            #expect(
                ExitGrace.closes(
                    empty.fileHandleForReading.fileDescriptor, readSinceLastCheck: false, check: 1))
        }

        /// A grandchild still writing: the reader keeps up, so what waits is new output.
        @Test func aPipeReadSinceTheLastCheckCloses() throws {
            let full = try pipe("omarchy")
            #expect(
                ExitGrace.closes(full.fileHandleForReading.fileDescriptor, readSinceLastCheck: true, check: 1)
            )
        }

        @Test func theLastCheckClosesAnyway() throws {
            let full = try pipe("omarchy")
            let descriptor = full.fileHandleForReading.fileDescriptor
            #expect(!ExitGrace.closes(descriptor, readSinceLastCheck: false, check: ExitGrace.checks - 1))
            #expect(ExitGrace.closes(descriptor, readSinceLastCheck: false, check: ExitGrace.checks))
        }

        /// A grandchild holding the pipes, quiet: the output still ends about a second after the
        /// process, with what it wrote.
        @Test func aQuietGrandchildLetsTheOutputEnd() async throws {
            let connection = try ProcessConnection.launch(
                executable: URL(filePath: "/bin/sh"), arguments: ["-c", "echo omarchy; (sleep 4) & exit 0"],
                classify: SSHErrorClassifier.classify)
            let start = ContinuousClock.now
            var bytes: [UInt8] = []
            for try await chunk in connection.incoming { bytes += chunk }
            #expect(String(decoding: bytes, as: UTF8.self) == "omarchy\n")
            #expect(ContinuousClock.now - start < .seconds(3))
        }

        /// A grandchild writing on: the output ends at the first check, not the last.
        @Test func aWritingGrandchildLetsTheOutputEnd() async throws {
            let connection = try ProcessConnection.launch(
                executable: URL(filePath: "/bin/sh"),
                arguments: [
                    "-c",
                    "(i=0; while [ $i -lt 80 ]; do echo omarchy; sleep 0.05; i=$((i+1)); done) & exit 0",
                ],
                classify: SSHErrorClassifier.classify)
            let start = ContinuousClock.now
            for try await _ in connection.incoming {}
            #expect(ContinuousClock.now - start < .seconds(3))
        }
    }
#endif
