import GliffProtocol
import Testing

@testable import GliffSession

/// A virtual screen's Resolution: Retina asks for every pixel of the window; Standard for half
/// a side (a quarter of the pixels) on a Retina display, for an encoder that can't keep up.
/// Automatic is Standard on a CPU pipeline.
@Suite struct VirtualResolutionTests {
    private func factor(
        _ resolution: VirtualResolution, pipeline: VideoPipeline? = nil, backing: Double = 2,
        _ width: UInt32 = 3024, _ height: UInt32 = 1964
    ) -> Double {
        resolution.factor(pipeline: pipeline, backingScale: backing, width: width, height: height)
    }

    @Test func retinaIsOne() {
        #expect(factor(.retina) == 1)
        #expect(factor(.retina, pipeline: .cpu) == 1)
    }

    @Test func standardIsHalfOnRetina() {
        #expect(factor(.standard) == 0.5)
    }

    @Test func standardNeedsARetinaDisplay() {
        #expect(factor(.standard, backing: 1) == 1)
    }

    @Test func automaticFollowsThePipeline() {
        #expect(factor(.automatic, pipeline: .cpu) == 0.5)
        #expect(factor(.automatic, pipeline: .gpu) == 1)
        #expect(factor(.automatic) == 1)
    }

    /// At half, the server's smallest screen (320×240) must still fit.
    @Test func aSmallWindowFallsBackToRetina() {
        #expect(factor(.standard, backing: 2, 639, 480) == 1)
        #expect(factor(.standard, backing: 2, 640, 479) == 1)
        #expect(factor(.standard, backing: 2, 640, 480) == 0.5)
    }
}
