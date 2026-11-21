import Testing

@testable import GliffProtocol

@Test func protocolVersionIsOne() {
    #expect(GliffProtocol.version == 1)
    #expect(GliffProtocol.features.isEmpty)
}

@Test func errorCodesMatchUpstream() {
    #expect(ErrorCode.version == 1)
    #expect(ErrorCode.noChroma == 2)
    #expect(ErrorCode.noCodec == 3)
    #expect(ErrorCode.setup == 256)
}

@Test(arguments: [
    (UInt16(0), false), (1, true), (3, true), (255, true), (256, false), (.max, false),
])
func incompatibleRangeIsOneTo255(code: UInt16, incompatible: Bool) {
    #expect(ErrorCode.isIncompatible(code) == incompatible)
}
