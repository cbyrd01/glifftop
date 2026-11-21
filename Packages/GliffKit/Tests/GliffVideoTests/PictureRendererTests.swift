import Foundation
import Metal
import Testing

@testable import GliffVideo

struct PictureRendererTests {
    @Test func oneToOneIsAnExactCopy() throws {
        let bars = try SyntheticFixtures.planes("bars-192x108")
        let picture = try Self.picture(bars.expected, width: 192, height: 108)
        #expect(
            try Self.render(picture, into: MetalTestSupport.output(width: 192, height: 108)) == bars.expected)
    }

    /// 192×108 in 192×200: 46 black rows, the picture 1:1, 46 black rows.
    @Test func letterboxIsBlack() throws {
        let bars = try SyntheticFixtures.planes("bars-192x108")
        let picture = try Self.picture(bars.expected, width: 192, height: 108)
        let pixels = try Self.render(picture, into: MetalTestSupport.output(width: 192, height: 200))
        let row = 192 * 4
        let black: [UInt8] = (0..<(row * 46)).map { $0 % 4 == 3 ? 255 : 0 }
        #expect(Array(pixels[..<(row * 46)]) == black)
        #expect(Array(pixels[(row * 46)..<(row * 154)]) == bars.expected)
        #expect(Array(pixels[(row * 154)...]) == black)
    }

    /// One renderer, pictures of different sizes: each draws at its own size.
    @Test func rendererFollowsPictureSize() throws {
        let renderer = try PictureRenderer(device: MetalTestSupport.device)
        let small = try SyntheticFixtures.planes("bars-192x108")
        let large = try SyntheticFixtures.planes("gradient-256x144")
        let target = MetalTestSupport.output(width: 256, height: 144)
        _ = try Self.render(
            try Self.picture(small.expected, width: 192, height: 108), into: target, renderer: renderer)
        let pixels = try Self.render(
            try Self.picture(large.expected, width: 256, height: 144), into: target, renderer: renderer)
        #expect(pixels == large.expected)
    }

    /// 192×108 in 96×80 is scaled to 96×54: 13 black rows above and below, picture between.
    @Test func scaledDownPictureIsLetterboxed() throws {
        let bars = try SyntheticFixtures.planes("bars-192x108")
        let picture = try Self.picture(bars.expected, width: 192, height: 108)
        let pixels = try Self.render(picture, into: MetalTestSupport.output(width: 96, height: 80))
        let row = 96 * 4
        let black: [UInt8] = (0..<(row * 13)).map { $0 % 4 == 3 ? 255 : 0 }
        #expect(Array(pixels[..<(row * 13)]) == black)
        #expect(Array(pixels[(row * 67)...]) == black)
        // Every picture row has colour in it (the bars have no all-black row).
        for y in 13..<67 {
            #expect(
                pixels[(y * row)..<((y + 1) * row)].enumerated().contains {
                    $0.offset % 4 != 3 && $0.element > 0
                })
        }
    }

    /// A stream the server scaled down (96×54 for a 192×108 view) is stretched to fill the
    /// view it carries, as upstream's client does: no black border, and linear filtering, so
    /// the seam between its two halves blends.
    @Test func scaledDownStreamFillsItsView() throws {
        let left: [UInt8] = [200, 0, 0, 255]
        let right: [UInt8] = [0, 0, 200, 255]
        let row =
            Array([[UInt8]](repeating: left, count: 48).joined())
            + Array([[UInt8]](repeating: right, count: 48).joined())
        let halves = Array([[UInt8]](repeating: row, count: 54).joined())
        let picture = try Self.picture(
            halves, width: 96, height: 54, view: PixelSize(width: 192, height: 108))
        let pixels = try Self.render(picture, into: MetalTestSupport.output(width: 192, height: 108))
        func pixel(_ x: Int, _ y: Int) -> [UInt8] { Array(pixels[(y * 192 + x) * 4..<(y * 192 + x) * 4 + 4]) }
        #expect(pixel(0, 0) == left && pixel(191, 107) == right)
        #expect(pixel(0, 107) == left && pixel(191, 0) == right)
        // Output column 95 samples between texels 47 and 48: a blend, never either colour.
        #expect(pixel(95, 50) != left && pixel(95, 50) != right)
    }

    @Test func targetOfAnotherFormatThrows() throws {
        let renderer = try PictureRenderer(device: MetalTestSupport.device)
        let picture = try Self.picture([UInt8](repeating: 0, count: 16 * 16 * 4), width: 16, height: 16)
        let target = MetalTestSupport.output(width: 16, height: 16, pixelFormat: .rgba8Unorm)
        let commandBuffer = try #require(MetalTestSupport.queue.makeCommandBuffer())
        #expect(throws: VideoError.textureFormat) {
            try renderer.encode(picture, into: target, commandBuffer: commandBuffer, scaleToFit: false)
        }
    }

    /// The renderer holds the picture until the GPU is done, so a caller that lets go right
    /// after encoding can't have its texture recycled mid-draw.
    @Test func pictureIsHeldUntilTheDrawCompletes() throws {
        let renderer = try PictureRenderer(device: MetalTestSupport.device)
        let pool = PicturePool(width: 16, height: 16, count: 1) { width, height in
            MetalTestSupport.output(width: width, height: height)
        }
        let commandBuffer = try #require(MetalTestSupport.queue.makeCommandBuffer())
        do {
            let picture = try #require(try pool.acquire())
            try renderer.encode(
                picture, into: MetalTestSupport.output(width: 16, height: 16), commandBuffer: commandBuffer,
                scaleToFit: false)
        }
        #expect(try pool.acquire() == nil)
        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()
        // Completed handlers run after waitUntilCompleted may return: give them a moment.
        var recycled = try pool.acquire()
        for _ in 0..<100 where recycled == nil {
            Thread.sleep(forTimeInterval: 0.01)
            recycled = try pool.acquire()
        }
        #expect(recycled != nil)
    }

    /// Scale to Fit: a 64×36 picture into 128×72 fills it, the right way round: its left half
    /// on the left, no black border.
    @Test func scaleToFitFillsTheTarget() throws {
        let left: [UInt8] = [200, 0, 0, 255]
        let right: [UInt8] = [0, 0, 200, 255]
        let row =
            Array([[UInt8]](repeating: left, count: 32).joined())
            + Array([[UInt8]](repeating: right, count: 32).joined())
        let picture = try Self.picture(
            Array([[UInt8]](repeating: row, count: 36).joined()), width: 64, height: 36)
        let pixels = try Self.render(
            picture, into: MetalTestSupport.output(width: 128, height: 72), scaleToFit: true)
        func pixel(_ x: Int, _ y: Int) -> [UInt8] { Array(pixels[(y * 128 + x) * 4..<(y * 128 + x) * 4 + 4]) }
        #expect(pixel(0, 0) == left && pixel(0, 71) == left && pixel(60, 36) == left)
        #expect(pixel(127, 0) == right && pixel(127, 71) == right && pixel(67, 36) == right)
    }

    // MARK: - Helpers

    /// A picture holding `bgra`, in a shared texture (the pool's seam).
    private static func picture(_ bgra: [UInt8], width: Int, height: Int, view: PixelSize? = nil) throws
        -> Picture
    {
        let pool = PicturePool(width: width, height: height, view: view, count: 1) { width, height in
            let texture = MetalTestSupport.output(width: width, height: height)
            bgra.withUnsafeBytes { bytes in
                texture.replace(
                    region: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0,
                    withBytes: bytes.baseAddress!, bytesPerRow: width * 4)
            }
            return texture
        }
        return try #require(try pool.acquire())
    }

    /// Renders `picture` into `target` and reads it back.
    private static func render(
        _ picture: Picture, into target: any MTLTexture, renderer: PictureRenderer? = nil,
        scaleToFit: Bool = false
    ) throws -> [UInt8] {
        let renderer = try renderer ?? PictureRenderer(device: MetalTestSupport.device)
        try MetalTestSupport.run { commandBuffer in
            try renderer.encode(picture, into: target, commandBuffer: commandBuffer, scaleToFit: scaleToFit)
        }
        return MetalTestSupport.readBGRA(target)
    }
}
