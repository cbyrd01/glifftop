import Metal
import Testing

@testable import GliffVideo

struct PicturePoolTests {
    /// A texture Metal can't make is an error, not a full pool, and doesn't use up a place.
    @Test func allocationFailureThrows() throws {
        let pool = PicturePool(width: 16, height: 16, count: 1) { _, _ in nil }
        #expect(throws: VideoError.pictureAllocation) { try pool.acquire() }
        #expect(throws: VideoError.pictureAllocation) { try pool.acquire() }
    }

    @Test func fullPoolGivesNil() throws {
        let pool = PicturePool(device: MetalTestSupport.device, width: 16, height: 16, count: 1)
        let held = try #require(try pool.acquire())
        #expect(try pool.acquire() == nil)
        withExtendedLifetime(held) {}
    }

    @Test func picturesCarryTheScale() throws {
        let pool = PicturePool(
            device: MetalTestSupport.device, width: 16, height: 16, scaleMilli: 1250, count: 1)
        let picture = try #require(try pool.acquire())
        #expect(picture.scaleMilli == 1250)
    }

    /// A scale-only StreamConfig keeps the stream: the picture on screen takes the new scale.
    @Test func aScaleUpdateReachesThePictureOnScreen() throws {
        let pool = PicturePool(device: MetalTestSupport.device, width: 16, height: 16, count: 1)
        let picture = try #require(try pool.acquire())
        #expect(picture.scaleMilli == 1000)
        let view = PixelSize(width: 32, height: 32)
        pool.update(view: view, scaleMilli: 2000)
        #expect(picture.geometry == (view, 2000))
    }
}
