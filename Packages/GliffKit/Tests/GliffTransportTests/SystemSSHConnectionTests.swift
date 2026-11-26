#if os(macOS)
    import Foundation
    import Synchronization
    import Testing

    @testable import GliffTransport

    /// `SystemSSHConnection` against a stub `ssh`: a shell script that plays the master (a file
    /// at the socket path holding its pid, removed when it ends), `-O check`, `-O exit`, and
    /// channels that echo their stdin while the master lives. With `STUB_ASK`, the master first
    /// asks it through `$SSH_ASKPASS` (the helper SwiftPM builds), as ssh does, and keeps the
    /// answer in `answer`; it records its arguments and `$SSH_ASKPASS` in `args` and `askpass`.
    @Suite final class SystemSSHConnectionTests {
        let root = URL(filePath: "/tmp/ssc-\(UUID().uuidString.prefix(8))")
        var socket: String { root.path + "/1-1" }

        init() throws {
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        }

        deinit { try? FileManager.default.removeItem(at: root) }

        /// The helper as SwiftPM builds it (`swift test` builds every target).
        static let helper = URL(filePath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appending(path: ".build/debug/glifftop-askpass-swiftpm")

        struct Asker: SignInAsker {
            let answer: @Sendable (SignInQuestion) async -> SignInAnswer
            func ask(_ question: SignInQuestion) async -> SignInAnswer { await answer(question) }
        }

        static let password = "person@omarchy's password: "
        static let hostKey =
            "The authenticity of host 'omarchy (2001:db8::1)' can't be established.\n"
            + "ED25519 key fingerprint is: SHA256:ASFf47m3ZeIPySUT2MoJMWo0cEUXbpBbhcPi49mvyF8\n"
            + "Are you sure you want to continue connecting (yes/no/[fingerprint])? "

        /// Opens through the probe's path, with `config` in place of `ssh -G`'s and the stub's
        /// shell (bash) as the ssh the helper's parent must be.
        func open(
            _ environment: String, config: SSHResolvedConfig? = SSHResolvedConfig(resolved: ""),
            limit: Duration = .seconds(60), ceiling: Duration = .seconds(300),
            asking answer: (@Sendable (SignInQuestion) async -> SignInAnswer)?
        ) async throws -> SystemSSHConnection {
            try await SystemSSHConnection.open(
                target: SSHTarget("omarchy"), socket: socket, config: config,
                questions: answer.map { Asker(answer: $0) }, helper: Self.helper,
                executable: stub(environment),
                ssh: "/bin/bash", limit: limit, ceiling: ceiling)
        }

        func file(_ name: String) -> String? {
            try? String(contentsOf: root.appending(path: name), encoding: .utf8)
        }

        @Test func anAskingMasterGetsItsAnswer() async throws {
            let asked = Mutex<[SignInQuestion]>([])
            let connection = try await open("STUB_ASK=\"\(Self.password)\"") { question in
                asked.withLock { $0.append(question) }
                return .secret(SignInSecret(copying: "pw"))
            }
            #expect(file("answer") == "pw")
            #expect(asked.withLock { $0.count } == 1)
            #expect(file("askpass") == Self.helper.path)
            #expect(file("args")?.contains("StrictHostKeyChecking=ask") == true)
            #expect(file("args")?.contains("BatchMode=yes") == false)
            await connection.close()
        }

        /// The limit leaves a busy machine time to start ssh and the helper before the question.
        @Test func aQuestionPausesTheSignInLimit() async throws {
            let connection = try await open("STUB_ASK=\"\(Self.password)\"", limit: .seconds(3)) { _ in
                try? await Task.sleep(for: .seconds(4))
                return .secret(SignInSecret(copying: "pw"))
            }
            #expect(file("answer") == "pw")
            await connection.close()
        }

        /// The ceiling leaves a busy machine time to start ssh and the helper before the question.
        @Test func theCeilingEndsALongQuestion() async throws {
            let asked = Mutex(false)
            await #expect(throws: TransportError.exited(status: 255, failure: .signInTimedOut)) {
                try await self.open("STUB_ASK=\"\(Self.password)\"", ceiling: .seconds(3)) { _ in
                    asked.withLock { $0 = true }
                    try? await Task.sleep(for: .seconds(30))
                    return .cancel
                }
            }
            #expect(asked.withLock { $0 })
            #expect(kill(try masterPID(), 0) != 0)
        }

        @Test func cancelFailsAsSignInCancelled() async throws {
            let failure = await failure(of: "STUB_ASK=\"\(Self.password)\"") { _ in .cancel }
            #expect(failure == .signInCancelled)
            #expect(file("answer") == nil)
            #expect(kill(try masterPID(), 0) != 0)
        }

        /// An open cancelled with no question open (its last window gone) ends ssh before its
        /// bridge goes: a question ssh started in between would find no bridge, and ssh would send
        /// an empty answer.
        @Test func aCancelledOpenEndsSSHBeforeTheBridgeGoes() async throws {
            let (executable, socket) = (try stub("STUB_LATE=\"\(Self.password)\""), socket)
            let opening = Task {
                try await SystemSSHConnection.open(
                    target: SSHTarget("omarchy"), socket: socket, config: SSHResolvedConfig(resolved: ""),
                    questions: Asker { _ in .cancel }, helper: Self.helper, executable: executable,
                    ssh: "/bin/bash")
            }
            #expect(await eventually { self.writtenMasterPID() != nil })
            opening.cancel()
            await #expect(throws: TransportError.cancelled) { try await opening.value }
            try await Task.sleep(for: .milliseconds(300))
            #expect(file("late") == nil)
        }

        @Test func denyFailsAsHostKeyDenied() async throws {
            let failure = await failure(of: "STUB_ASK=\"\(Self.hostKey)\"") { _ in .deny }
            #expect(failure == .hostKeyDenied)
            #expect(file("answer") == "no")
        }

        @Test func noQuestionsMeansBatchMode() async throws {
            let connection = try await open("", asking: nil)
            #expect(file("args")?.contains("BatchMode=yes") == true)
            #expect(file("bridge") == "")
            await connection.close()
        }

        @Test func aFailedProbeMeansBatchMode() async throws {
            let connection = try await open("", config: nil) { _ in .cancel }
            #expect(file("args")?.contains("BatchMode=yes") == true)
            #expect(file("bridge") == "")
            await connection.close()
        }

        @Test func theBridgeIsGoneOnceReady() async throws {
            let connection = try await open("STUB_ASK=\"\(Self.password)\"") { _ in
                .secret(SignInSecret(copying: "pw"))
            }
            #expect(!FileManager.default.fileExists(atPath: socket + "-a"))
            await connection.close()
        }

        /// The known_hosts name for `ssh-keygen -R` comes from the probe, never from stderr.
        @Test func anUnknownQuestionFailsAsOne() {
            let failure = SystemSSHConnection.failure(
                .exited(status: 255, failure: .permissionDenied), outcome: .unknownQuestion,
                knownHostsName: nil)
            #expect(failure == .exited(status: 255, failure: .unknownQuestion))
        }

        @Test func aChangedKeyNamesTheProbesKnownHostsName() async throws {
            let changed =
                "@ WARNING: REMOTE HOST IDENTIFICATION HAS CHANGED! @\nThe fingerprint for the ED25519 key sent by the remote host is\nSHA256:new.\nHost key verification failed."
            let config = SSHResolvedConfig(resolved: "hostname 192.0.2.7\nport 2222\n")
            let failure = await failure(of: "STUB_CHANGED='\(changed)'", config: config, asking: nil)
            #expect(failure == .changedHostKey(fingerprint: "SHA256:new", knownHostsName: "[192.0.2.7]:2222"))
        }

        /// A jump host's ssh asking is ended with the master (its process group) before its
        /// helper goes, so it never sends an empty answer.
        @Test func cancelEndsAJumpHostsSSHBeforeItAnswers() async throws {
            let asked = Mutex(0)
            let failure = await failure(of: "STUB_JUMP=\"\(Self.password)\"") { _ in
                asked.withLock { $0 += 1 }
                return .cancel
            }
            #expect(failure == .signInCancelled)
            #expect(asked.withLock { $0 } == 1)
            try await Task.sleep(for: .milliseconds(300))
            #expect(file("jump") == nil)
        }

        /// Through a jump host, a changed key may be the jump host's: no name is offered.
        @Test func aChangedKeyThroughAJumpHostNamesNoEntry() async throws {
            let changed =
                "@ WARNING: REMOTE HOST IDENTIFICATION HAS CHANGED! @\nThe fingerprint for the ED25519 key sent by the remote host is\nSHA256:new.\nHost key verification failed."
            let config = SSHResolvedConfig(resolved: "hostname 192.0.2.7\nproxyjump bastion\n")
            let failure = await failure(of: "STUB_CHANGED='\(changed)'", config: config, asking: nil)
            #expect(failure == .changedHostKey(fingerprint: "SHA256:new", knownHostsName: nil))
        }

        /// Why an open failed, or nil if it didn't fail that way.
        func failure(
            of environment: String, config: SSHResolvedConfig? = SSHResolvedConfig(resolved: ""),
            asking answer: (@Sendable (SignInQuestion) async -> SignInAnswer)?
        ) async -> ConnectFailure? {
            do {
                let connection = try await open(environment, config: config, asking: answer)
                await connection.close()
                return nil
            } catch {
                guard case .exited(_, let failure) = error as? TransportError else { return nil }
                return failure
            }
        }

        func open(_ environment: String = "") async throws -> SystemSSHConnection {
            try await SystemSSHConnection.open(
                command: SSHMasterCommand(target: SSHTarget("omarchy"), socket: socket),
                executable: stub(environment))
        }

        @Test func openWaitsForTheCheck() async throws {
            let connection = try await open("STUB_DELAY=0.3")
            #expect(FileManager.default.fileExists(atPath: socket))
            await connection.close()
        }

        @Test func aMasterThatExitsFailsTheOpen() async throws {
            await #expect(throws: TransportError.exited(status: 255, failure: .permissionDenied)) {
                try await self.open("STUB_REFUSE=1")
            }
        }

        @Test func aChannelSpeaksThroughIt() async throws {
            let connection = try await open()
            let channel = try await connection.channel(command: "gliff-server --stdio")
            try await channel.write(Array("hello\n".utf8))
            var chunks = channel.incoming.makeAsyncIterator()
            #expect(try await chunks.next() == Array("hello\n".utf8))
            await channel.close()
            await connection.close()
        }

        @Test func masterExitEndsItsChannels() async throws {
            let connection = try await open()
            let channel = try await connection.channel(command: "gliff-server --stdio")
            kill(try masterPID(), SIGTERM)
            #expect(await connection.ended() == .unreachable)
            let started = ContinuousClock.now
            await #expect(throws: TransportError.exited(status: 255, failure: .sharedConnectionLost)) {
                for try await _ in channel.incoming {}
            }
            #expect(ContinuousClock.now - started < .seconds(2))
            await #expect(throws: TransportError.exited(status: 255, failure: .sharedConnectionLost)) {
                try await connection.channel(command: "late")
            }
        }

        /// The config's local forwards are reported, never asked of the master by the
        /// connection itself: GliffPorts applies them.
        @Test func theConfigsForwardsAreReportedNotAsked() async throws {
            let config = SSHResolvedConfig(
                resolved: "localforward 3000 [localhost]:3000\nlocalforward 3001 [db]:5432\n")
            let connection = try await open("", config: config, asking: nil)
            let configured = await connection.configuredForwards
            #expect(configured.local.map { $0.forward.localPort } == [3000, 3001])
            let channel = try await connection.channel(command: "gliff-server --stdio")
            await channel.close()
            #expect(file("forwards") == nil)
            await connection.close()
        }

        @Test func closeRemovesTheSocket() async throws {
            let connection = try await open()
            await connection.close()
            #expect(await connection.ended() == nil)
            #expect(!FileManager.default.fileExists(atPath: socket))
        }

        /// The master's pid, which the stub writes beside the socket, once it has.
        func writtenMasterPID() -> Int32? { Self.writtenMasterPID(in: root) }

        static func writtenMasterPID(in root: URL) -> Int32? {
            (try? String(contentsOf: root.appending(path: "master.pid"), encoding: .utf8))
                .flatMap { Int32($0.trimmingCharacters(in: .whitespacesAndNewlines)) }
        }

        func masterPID() throws -> Int32 { try #require(writtenMasterPID()) }

        @Test func aMasterEndingByItselfIsALoss() async throws {
            let connection = try await open()
            kill(try masterPID(), SIGUSR1)
            #expect(await connection.ended() == .sharedConnectionLost)
        }

        @Test func aKilledMasterLeavesNoSocket() async throws {
            let connection = try await open()
            kill(try masterPID(), SIGKILL)
            #expect(await connection.ended() != nil)
            #expect(await eventually { !FileManager.default.fileExists(atPath: self.socket) })
        }

        @Test func aSignInThatNeverFinishesTimesOut() async throws {
            let command = try SSHMasterCommand(target: SSHTarget("omarchy"), socket: socket)
            let executable = try stub("STUB_DELAY=5")
            await #expect(throws: TransportError.exited(status: 255, failure: .signInTimedOut)) {
                try await SystemSSHConnection.open(
                    command: command, executable: executable, limit: .milliseconds(500))
            }
            #expect(kill(try masterPID(), 0) != 0)
        }

        @Test func aCloseIsNeverALoss() async throws {
            let connection = try await open("STUB_EXIT_STATUS=255")
            await connection.close()
            #expect(await connection.ended() == nil)
        }

        @Test func invalidateEndsItAsUnreachable() async throws {
            let connection = try await open()
            await connection.invalidate()
            #expect(await connection.ended() == .unreachable)
            #expect(!FileManager.default.fileExists(atPath: socket))
        }

        @Test func cancelledWhileOpeningEndsTheMaster() async throws {
            let executable = try stub("STUB_DELAY=5")
            let command = try SSHMasterCommand(target: SSHTarget("omarchy"), socket: socket)
            let opening = Task {
                try await SystemSSHConnection.open(command: command, executable: executable)
            }
            #expect(await eventually { self.writtenMasterPID() != nil })
            opening.cancel()
            let cancelled = ContinuousClock.now
            await #expect(throws: TransportError.cancelled) { try await opening.value }
            #expect(ContinuousClock.now - cancelled < .seconds(1))
            #expect(kill(try masterPID(), 0) != 0)
        }
    }
#endif
