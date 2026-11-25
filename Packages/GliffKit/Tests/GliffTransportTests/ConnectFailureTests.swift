import Testing

@testable import GliffTransport

/// The words a person sees for each failure a macro channel adds.
@Suite struct ConnectFailureTests {
    @Test func macroFailureMessagesAreExact() {
        #expect(ConnectFailure.macroFailed.message == "A start macro failed.")
        #expect(ConnectFailure.noRoomOnConnection.message == "The connection to the host is full.")
    }
}
