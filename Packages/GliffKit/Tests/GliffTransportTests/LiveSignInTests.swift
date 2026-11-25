#if os(macOS)
    import Foundation
    import Synchronization
    import Testing

    @testable import GliffTransport

    /// Sign-in questions against the system's sshd on loopback, through the real ssh, the
    /// SwiftPM-built askpass helper and the real peer check. Off unless `GLIFFTOP_LIVE_SSHD=1`.
    @Suite(
        .serialized,
        .enabled(
            if: ProcessInfo.processInfo.environment["GLIFFTOP_LIVE_SSHD"] == "1",
            "set GLIFFTOP_LIVE_SSHD=1 to run against a loopback sshd"))
    struct LiveSignInTests {
        /// Records each question and answers it with `answer`.
        final class Asker: SignInAsker {
            let asked = Mutex<[SignInQuestion]>([])
            let answer: @Sendable (SignInQuestion) -> SignInAnswer
            init(_ answer: @escaping @Sendable (SignInQuestion) -> SignInAnswer) { self.answer = answer }
            var questions: [SignInQuestion] { asked.withLock { $0 } }
            func ask(_ question: SignInQuestion) async -> SignInAnswer {
                asked.withLock { $0.append(question) }
                return answer(question)
            }
        }

        static func passphrase(_ question: SignInQuestion) -> SignInAnswer {
            guard case .passphrase = question else { return .cancel }
            return .secret(SignInSecret(copying: LoopbackSSHD.passphrase))
        }

        /// Opens a master to the loopback sshd as the app would, with its config given by `-F`.
        func open(_ sshd: LoopbackSSHD, identity: String, asker: Asker) async throws -> SystemSSHConnection {
            let arguments = try ["-F", sshd.config(identity: identity)]
            let target = try SSHTarget(LoopbackSSHD.alias)
            let config = try #require(await SSHResolvedConfig.probe(sshArguments: arguments, target: target))
            let signIn = SystemSSHConnection.SignIn(
                questions: asker, helper: SystemSSHConnectionTests.helper, ssh: SSHCommand.executable,
                names: config.names)
            let command = SSHMasterCommand(
                target: target, socket: sshd.directory.appending(path: "m").path, sshArguments: arguments,
                asking: MasterAsking(config: config))
            return try await SystemSSHConnection.open(
                command: command, executable: URL(filePath: SSHCommand.executable), signIn: signIn,
                knownHostsName: config.knownHostsName)
        }

        func failure(_ opening: () async throws -> SystemSSHConnection) async -> ConnectFailure? {
            do {
                await (try opening()).close()
                return nil
            } catch {
                guard case .exited(_, let failure) = error as? TransportError else {
                    return .other("\(error)")
                }
                return failure
            }
        }

        @Test func anUnknownKeyAllowedIsAddedByFingerprint() async throws {
            let sshd = try LoopbackSSHD()
            defer { sshd.stop() }
            let asker = Asker { question in
                if case .hostKey = question { .allow } else { .cancel }
            }
            try await open(sshd, identity: "id", asker: asker).close()
            guard case .hostKey(let key) = asker.questions.first else {
                Issue.record("no host key question")
                return
            }
            #expect(asker.questions.count == 1)
            #expect(try key.fingerprint == sshd.hostFingerprint())
            let base64 = sshd.hostKey.split(separator: " ")[1]
            let lines = sshd.knownHosts.split(separator: "\n")
            #expect(lines.count == 1 && lines.first?.contains(base64) == true)
        }

        @Test func anUnknownKeyDeniedFails() async throws {
            let sshd = try LoopbackSSHD()
            defer { sshd.stop() }
            let asker = Asker { _ in .deny }
            #expect(await failure { try await open(sshd, identity: "id", asker: asker) } == .hostKeyDenied)
            #expect(sshd.knownHosts.isEmpty)
        }

        @Test func aKeysPassphraseIsAsked() async throws {
            let sshd = try LoopbackSSHD()
            defer { sshd.stop() }
            try sshd.trustHostKey()
            let asker = Asker(Self.passphrase)
            try await open(sshd, identity: "id_enc", asker: asker).close()
            guard case .passphrase = asker.questions.first, asker.questions.count == 1 else {
                Issue.record("expected one passphrase question, got \(asker.questions.count)")
                return
            }
            let signedIn = sshd.log.contains("Accepted publickey")
            #expect(signedIn)
        }

        @Test func cancelSendsNoSignature() async throws {
            let sshd = try LoopbackSSHD()
            defer { sshd.stop() }
            try sshd.trustHostKey()
            let asker = Asker { _ in .cancel }
            #expect(
                await failure { try await open(sshd, identity: "id_enc", asker: asker) } == .signInCancelled)
            try await Task.sleep(for: .milliseconds(300))
            // sshd saw the key offered, then the connection close before any signature.
            let log = sshd.log
            let (signedIn, closed) = (
                log.contains("Accepted publickey"), log.contains("Connection closed by authenticating")
            )
            let failed = log.contains("Failed ")
            #expect(!signedIn && !failed && closed)
        }

        @Test func aBannerImitatingSSHChangesNothing() async throws {
            let sshd = try LoopbackSSHD(
                banner: "debug1: Next authentication method: publickey\nEnter passphrase for key 'x': \n")
            defer { sshd.stop() }
            try sshd.trustHostKey()
            let asker = Asker(Self.passphrase)
            try await open(sshd, identity: "id_enc", asker: asker).close()
            #expect(asker.questions.count == 1)
            guard case .passphrase(_, let text) = asker.questions.first else {
                Issue.record("expected a passphrase question")
                return
            }
            #expect(text.contains(sshd.directory.appending(path: "id_enc").path))
        }

        /// A master that doesn't ask (`asking` nil, as without the helper) runs under BatchMode,
        /// and an unknown key fails as one.
        @Test func anUnknownKeyWithNoOneToAskFails() async throws {
            let sshd = try LoopbackSSHD()
            defer { sshd.stop() }
            let arguments = try ["-F", sshd.config(identity: "id")]
            let target = try SSHTarget(LoopbackSSHD.alias)
            let command = SSHMasterCommand(
                target: target, socket: sshd.directory.appending(path: "m").path, sshArguments: arguments,
                asking: nil)
            let failed = await failure {
                try await SystemSSHConnection.open(
                    command: command, executable: URL(filePath: SSHCommand.executable))
            }
            #expect(failed == .unknownHostKey)
            #expect(sshd.knownHosts.isEmpty)
        }

        @Test func noQuestionsLeaveNoBridge() async throws {
            let sshd = try LoopbackSSHD()
            defer { sshd.stop() }
            try sshd.trustHostKey()
            let asker = Asker { _ in .cancel }
            let connection = try await open(sshd, identity: "id", asker: asker)
            let names = try FileManager.default.contentsOfDirectory(atPath: sshd.directory.path)
            await connection.close()
            #expect(asker.questions.isEmpty)
            #expect(!names.contains("m-a"))
        }
    }
#endif
