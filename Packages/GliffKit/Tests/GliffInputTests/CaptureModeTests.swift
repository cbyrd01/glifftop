import Foundation
import Testing

@testable import GliffInput

/// A window's mode travels with the request for a window opened from it (Show All Monitors).
@Suite struct CaptureModeTests {
    @Test(arguments: CaptureMode.allCases)
    func aModeRoundTrips(_ mode: CaptureMode) throws {
        let data = try JSONEncoder().encode(mode)
        #expect(try JSONDecoder().decode(CaptureMode.self, from: data) == mode)
    }
}
