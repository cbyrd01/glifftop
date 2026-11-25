#if os(macOS)
    import Testing

    /// The live checks' host commands, checked without a host: a window is closed with
    /// Hyprland's Lua dispatcher, and only by an address `hyprctl` gave.
    @Suite struct LiveHyprlandTests {
        @Test func closeCommandUsesTheLuaDispatcher() {
            #expect(
                LiveHyprland.closeCommand(address: "0x55d0c0ffee00")
                    == #"hyprctl dispatch 'hl.dsp.window.close({ window = "address:0x55d0c0ffee00" })'"#)
        }

        /// One window that won't close leaves no other open: every close is tried.
        @Test func aFailedCloseStillClosesTheRest() {
            struct Refused: Error {}
            var ran: [String] = []
            let failures = LiveHyprland.close(["0x1", "0x2"]) { command in
                ran.append(command)
                if ran.count == 1 { throw Refused() }
                return "ok"
            }
            #expect(ran.count == 2)
            #expect(ran.last?.contains(#""address:0x2""#) == true)
            #expect(failures.count == 1)
        }

        /// Only `hyprctl dispatch`'s "ok" is success: any other answer is a failure.
        @Test func aCloseThatDoesNotSayOkFails() {
            let failures = LiveHyprland.close(["0x1", "0x2"]) { command in
                command.contains("0x1") ? "ok\n" : "error: no such window\n"
            }
            #expect(failures.count == 1)
        }

        @Test(arguments: ["", "0x", "0x1; reboot", "0x1' )", "address:0x1", "0X1F"])
        func closeCommandRefusesAnythingButAnAddress(_ text: String) {
            #expect(LiveHyprland.closeCommand(address: text) == nil)
        }
    }
#endif
