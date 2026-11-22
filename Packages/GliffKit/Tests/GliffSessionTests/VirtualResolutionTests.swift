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

    /// Whether Standard's half-size picture is asked for, display and window aside.
    @Test func isStandardNamesTheChoiceInForce() {
        #expect(!VirtualResolution.retina.isStandard(pipeline: .cpu))
        #expect(VirtualResolution.standard.isStandard(pipeline: .gpu))
        #expect(VirtualResolution.automatic.isStandard(pipeline: .cpu))
        #expect(!VirtualResolution.automatic.isStandard(pipeline: .gpu))
        #expect(!VirtualResolution.automatic.isStandard(pipeline: nil))
    }

    /// A virtual screen's picture is Standard's when its scale is about half what the window
    /// asks at Retina: drawn scaled until the server answers a change.
    @Test func aHalfScalePictureIsStandards() {
        func half(_ scale: Double, backing: Double = 2, text: Double = 1) -> Bool {
            ViewTarget.isStandardPicture(screenScale: scale, backingScale: backing, textFactor: text)
        }
        #expect(half(1))
        #expect(!half(2))
        #expect(half(0.75, text: 0.75))
        #expect(!half(1.5, text: 0.75))
        // Under 1: Standard at the smallest text size.
        #expect(half(0.5, text: 0.5))
        // Text size changed, the old picture still showing.
        #expect(!half(2, text: 0.75))
        #expect(!half(1.5, text: 1))
        #expect(!half(1, backing: 1))
    }
}
