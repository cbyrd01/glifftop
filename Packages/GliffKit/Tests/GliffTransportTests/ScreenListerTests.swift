#if os(macOS)
    import Foundation
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
    }
#endif
