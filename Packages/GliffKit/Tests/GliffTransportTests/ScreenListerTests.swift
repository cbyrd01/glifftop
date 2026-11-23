#if os(macOS)
    import Foundation
    import GliffTestSupport
    import Testing

    @testable import GliffTransport

    /// Runs /bin/sh as a stand-in for ssh, as `ProcessTransportTests` does.
    @Suite(.timeLimit(.minutes(1))) struct ScreenListerTests {
        private func list(_ script: String, timeout: Duration = .seconds(10)) async throws(ScreenListError)
            -> [RemoteScreen]
        {
            try await ScreenLister(
                executable: URL(filePath: "/bin/sh"), arguments: ["-c", script], timeout: timeout
            ).screens()
        }

        private func failure(_ script: String, timeout: Duration = .seconds(10)) async -> ScreenListError? {
            do {
                _ = try await list(script, timeout: timeout)
                return nil
            } catch {
                return error
            }
        }

        @Test func printsAList() async throws {
            let json =
                #"[{"name":"DP-2","make":"A","model":"B","width":2560,"height":1440,"scale":1},"#
                + #"{"name":"DP-3","make":"A","model":"B","width":1920,"height":1080,"scale":1}]"#
            let screens = try await list("printf '%s' '\(json)'")
            #expect(screens.map(\.name) == ["DP-2", "DP-3"])
        }

        @Test func aFailingHostSaysWhy() async {
            let error = await failure("echo 'Permission denied (publickey).' >&2; exit 255")
            #expect(error == .failed(.permissionDenied))
        }

        @Test func aMissingHyprctlSaysSo() async {
            let error = await failure("echo 'sh: hyprctl: command not found' >&2; exit 127")
            #expect(error == .failed(.other("hyprctl isn't installed on the host, or isn't on its PATH.")))
        }

        @Test func noHyprlandSaysSo() async {
            let error = await failure("echo 'no Hyprland session is running' >&2; exit 3")
            #expect(error == .failed(.other("no Hyprland session is running")))
        }

        @Test func notJSONIsUnreadable() async {
            #expect(await failure("echo hello") == .unreadable)
        }

        /// A host that never answers (a 1Password prompt left open) ends with a
        /// message, and the process is gone.
        @Test func aListThatNeverEndsTimesOut() async throws {
            let pidFile = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
            defer { try? FileManager.default.removeItem(at: pidFile) }
            let start = ContinuousClock.now
            let error = await failure(
                "echo $$ > '\(pidFile.path)'; exec sleep 30", timeout: .milliseconds(500))
            #expect(error == .timedOut)
            #expect(ContinuousClock.now - start < .seconds(5))
            let pid = try #require(
                Int32(
                    String(decoding: try Data(contentsOf: pidFile), as: UTF8.self).trimmingCharacters(
                        in: .whitespacesAndNewlines)))
            // Gone, or its pid already reused by something other than the sleep.
            var name = [UInt8](repeating: 0, count: 64)
            #expect(
                kill(pid, 0) == -1
                    || (proc_name(pid, &name, 64) > 0
                        && String(decoding: name.prefix { $0 != 0 }, as: UTF8.self) != "sleep")
            )
        }

        @Test func tooMuchOutputIsRefused() async {
            #expect(await failure("head -c 2000000 /dev/zero") == .tooLarge)
        }

        /// Output that never ends is stopped at once, not after close()'s grace periods.
        @Test func endlessOutputStopsQuickly() async {
            let start = ContinuousClock.now
            #expect(await failure("exec cat /dev/zero") == .tooLarge)
            #expect(ContinuousClock.now - start < .seconds(1.5))
        }

        /// Whoever asked went away (the host was edited): cancelled, not a timeout.
        @Test func cancellingSaysCancelled() async {
            let task = Task { await failure("exec sleep 30") }
            try? await Task.sleep(for: .milliseconds(300))
            task.cancel()
            #expect(await task.value == ScreenListError.cancelled)
        }

        @Test func aProgramThatWontStartFails() async {
            let lister = ScreenLister(
                executable: URL(filePath: "/nonexistent/ssh"), arguments: [], timeout: .seconds(1))
            await #expect(throws: ScreenListError.self) { try await lister.screens() }
        }

        // On a shared connection: the app's way.

        /// A lister on a fake shared connection, and the channel it opens.
        private func overALease(
            timeout: Duration = .seconds(10), clock: any Clock<Duration> = ContinuousClock(),
            opener: FakeOpener = FakeOpener(), connections: HostConnections? = nil
        ) async throws
            -> (Task<[RemoteScreen], any Error>, FakeChannel, FakeOpener)
        {
            let connections = connections ?? HostConnections(open: opener.open)
            let lister = ScreenLister(
                connections: connections, target: try SSHTarget("omarchy"), timeout: timeout, clock: clock)
            let listing = Task { try await lister.screens() }
            try #require(await eventually { opener.made.first?.channels.count == 1 })
            return (listing, try #require(opener.made.first?.channels.first), opener)
        }

        @Test func screensComeOverALease() async throws {
            let (listing, channel, opener) = try await overALease()
            channel.send(
                Array(#"[{"name":"DP-2","make":"A","model":"B","width":2560,"height":1440,"scale":1}]"#.utf8))
            channel.end()
            #expect(try await listing.value.map(\.name) == ["DP-2"])
            let target = try SSHTarget("omarchy")
            #expect(opener.made.first?.commands == [ScreenListCommand(target: target).remoteCommand])
            #expect(channel.isClosed)
        }

        @Test func tooMuchOutputEndsTheChannel() async throws {
            let (listing, channel, _) = try await overALease()
            channel.send([UInt8](repeating: 0x20, count: ScreenListParser.maxBytes + 1))
            await #expect(throws: ScreenListError.tooLarge) { try await listing.value }
            #expect(channel.isClosed)
        }

        @Test func aSlowHostTimesOut() async throws {
            let (listing, channel, _) = try await overALease(timeout: .milliseconds(300))
            await #expect(throws: ScreenListError.timedOut) { try await listing.value }
            #expect(channel.isClosed)
        }

        /// The script's own line for a missing hyprctl, as a channel's failure carries it.
        @Test func aMissingHyprctlSaysSoOverAChannel() async throws {
            let (listing, channel, _) = try await overALease()
            channel.fail(.exited(status: 127, failure: .other("hyprctl: command not found")))
            await #expect(
                throws: ScreenListError.failed(
                    .other("hyprctl isn't installed on the host, or isn't on its PATH."))
            ) {
                try await listing.value
            }
        }

        /// The list comes only at the script's end: a slow one is not a dead link.
        @Test func aSlowListingLeavesTheConnectionAlone() async throws {
            let clock = ManualClock()
            let (listing, channel, opener) = try await overALease(timeout: .seconds(60), clock: clock)
            #expect(await clock.waitForSleepers(1))
            clock.advance(by: .seconds(20))
            try await Task.sleep(for: .milliseconds(50))
            #expect(opener.made.first?.invalidateCount == 0)
            channel.send(Array("[]".utf8))
            channel.end()
            #expect(try await listing.value.isEmpty)
        }

        /// A listing that runs out of time ends alone: its watchdog waits past the limit, so
        /// it never ends the host's connection first.
        @Test func aListingAtItsLimitLeavesTheConnectionAlone() async throws {
            let clock = ManualClock()
            let (listing, _, opener) = try await overALease(timeout: .seconds(60), clock: clock)
            #expect(await clock.waitForSleepers(1))
            clock.advance(by: .seconds(60))
            try await Task.sleep(for: .milliseconds(50))
            #expect(opener.made.first?.invalidateCount == 0)
            listing.cancel()
        }

        /// Get Screens is the person's own try: it asks for the sign-in again.
        @Test func getScreensAsksAgain() async throws {
            let opener = FakeOpener()
            let connections = HostConnections(open: opener.open)
            opener.failNext(.exited(status: 255, failure: .agentRefused))
            await #expect(throws: TransportError.self) {
                try await connections.lease(for: SSHTarget("omarchy"))
            }
            let (listing, channel, _) = try await overALease(opener: opener, connections: connections)
            channel.send(Array("[]".utf8))
            channel.end()
            #expect(try await listing.value.isEmpty)
        }

        @Test func aConnectionThatCantStartSaysWhy() async throws {
            let opener = FakeOpener()
            opener.failNext(.launchFailed("There's no private folder for ssh's connections."))
            let lister = ScreenLister(
                connections: HostConnections(open: opener.open), target: try SSHTarget("omarchy"))
            await #expect(
                throws: ScreenListError.failed(.other("There's no private folder for ssh's connections."))
            ) {
                try await lister.screens()
            }
        }
    }
#endif
