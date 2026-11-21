import Testing

@testable import GliffProtocol

@Suite struct ClientMessageFixtureTests {
    @Test func everyClientFixtureHasAnExpectedValue() throws {
        #expect(Set(expectedClientMessages.keys) == Set(try fixtureNames(prefix: "c")))
    }

    /// Byte-exact: upstream's server decodes what upstream's client encodes, so matching its
    /// bytes is the strongest check we have.
    @Test(arguments: expectedClientMessages.keys.sorted())
    func encodesByteExact(name: String) throws {
        let message = try #require(expectedClientMessages[name])
        #expect(message.encoded == (try fixture(name)))
    }
}
