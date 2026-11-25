#if os(macOS)
    import Foundation
    import Testing

    @testable import GliffTransport

    /// `HyprlandLookup.function`, run by /bin/sh against `FakeHyprland`: it exports the
    /// signature of an instance that answers, and otherwise says nothing and goes on.
    @Suite(.timeLimit(.minutes(1))) struct HyprlandLookupTests {
        /// The function, its call, then its status and the variable it leaves.
        private static let probe =
            HyprlandLookup.function
            + "; glifftop_find_hyprland; echo \"after=$? sig=${HYPRLAND_INSTANCE_SIGNATURE-unset}\""

        @Test func noRuntimeDirectoryFindsNothingQuietly() throws {
            let host = try FakeHyprland(live: [])
            let result = try host.run(Self.probe, runtimeDirectory: false)
            #expect(result.status == 0)
            #expect(result.output == "after=1 sig=unset\n")
        }

        @Test func noAnsweringInstanceFindsNothingQuietly() throws {
            let host = try FakeHyprland(live: [])
            try host.instance("crashed")
            #expect(try host.run(Self.probe).output == "after=1 sig=unset\n")
        }

        @Test func noHyprctlFindsNothingQuietly() throws {
            let host = try FakeHyprland(live: [], hyprctl: false)
            try host.instance("a")
            #expect(try host.run(Self.probe).output == "after=1 sig=unset\n")
        }

        @Test func theNewestAnsweringInstanceIsExported() throws {
            let host = try FakeHyprland(live: ["live"])
            try host.instance("live")
            try host.instance("crashed")
            let result = try host.run(Self.probe + "; sh -c 'echo child=$HYPRLAND_INSTANCE_SIGNATURE'")
            #expect(result.output == "after=0 sig=live\nchild=live\n")
        }

        /// With `print`, the monitor list it read, once.
        @Test func printWritesTheListItRead() throws {
            let host = try FakeHyprland(live: ["live"])
            try host.instance("live")
            let script = HyprlandLookup.function + "; glifftop_find_hyprland print"
            #expect(try host.run(script).output == FakeHyprland.monitors + "\n")
        }

        @Test func theSessionsOwnSignatureComesFirst() throws {
            let host = try FakeHyprland(live: ["mine", "newer"])
            try host.instance("mine")
            try host.instance("newer")
            #expect(try host.run(Self.probe, signature: "mine").output == "after=0 sig=mine\n")
        }

        @Test func itKeepsThePersonsVariables() throws {
            let host = try FakeHyprland(live: ["live"])
            try host.instance("live")
            let script =
                "dir=d; sig=s; out=o; " + Self.probe
                + "; echo \"$dir$sig$out\"; set | grep -c '^glifftop_[a-z_]*='"
            #expect(try host.run(script).output == "after=0 sig=live\ndso\n0\n")
        }

        /// csh and tcsh refuse a newline inside single quotes, which `shellQuoted` adds.
        @Test func theFunctionIsOneLineWithoutQuotes() {
            #expect(!HyprlandLookup.function.contains("\n"))
            #expect(!HyprlandLookup.function.contains("'"))
        }
    }
#endif
