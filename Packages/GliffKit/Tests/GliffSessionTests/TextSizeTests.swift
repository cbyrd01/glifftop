import Testing

@testable import GliffSession

/// A virtual screen's text size: the remote scale it asks for, and which steps change nothing
/// on a display.
@Suite struct TextSizeTests {
    @Test func remoteScaleIsTheBackingScaleTimesTheFactor() {
        #expect(TextSize.mac.remoteScale(backingScale: 2) == 2)
        #expect(TextSize.f875.remoteScale(backingScale: 2) == 1.75)
        #expect(TextSize.f50.remoteScale(backingScale: 2) == 1)
        // Never below 1.
        #expect(TextSize.f50.remoteScale(backingScale: 1) == 1)
    }

    /// On a 1× display every step is the Mac's own; on 2× only those reaching 1× again.
    @Test func changesNothingWhenALargerStepGivesTheSameScale() {
        #expect(
            TextSize.allCases.filter { $0.changesNothing(backingScale: 1) }
                == Array(TextSize.allCases.dropFirst()))
        #expect(TextSize.allCases.filter { $0.changesNothing(backingScale: 2) } == [])
        #expect(TextSize.f50.factor == 0.5)
    }
}
