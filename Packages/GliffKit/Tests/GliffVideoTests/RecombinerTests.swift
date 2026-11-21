import Metal
import Testing

@testable import GliffVideo

struct RecombinerTests {
    /// One pipeline for every case (Swift Testing makes a suite instance per test).
    static let shared = Result { try Recombiner(device: MetalTestSupport.device) }
    var recombiner: Recombiner { get throws { try Self.shared.get() } }

    @Test(arguments: SyntheticFixtures.names)
    func dualMatchesUpstreamWithinOne(name: String) throws {
        let set = try SyntheticFixtures.planes(name)
        #expect(MetalTestSupport.maxDifference(try recombine(set, dual: true), set.expected) <= 1)
    }

    @Test(arguments: SyntheticFixtures.names)
    func singleMatchesUpstreamWithinOne(name: String) throws {
        let set = try SyntheticFixtures.planes(name)
        #expect(MetalTestSupport.maxDifference(try recombine(set, dual: false), set.expectedSingle) <= 1)
    }

    /// Upstream's shader swizzles to `.bgr` for a Vulkan image viewed as RGBA; Metal's
    /// `bgra8Unorm` already stores B, G, R, A, so a copied swizzle would show red as blue.
    @Test func redStaysRed() throws {
        let set = try SyntheticFixtures.planes("bars-192x108")
        let picture = try recombine(set, dual: true)
        let index = (54 * set.main.width + 5 * 24 + 12) * 4
        #expect(MetalTestSupport.maxDifference(Array(picture[index..<index + 4]), [0, 0, 255, 255]) <= 1)
    }

    /// The planes must cover the stream: the kernel never reads outside them.
    @Test func planesSmallerThanTheStreamThrow() throws {
        let set = try SyntheticFixtures.planes("bars-192x108")
        let main = MetalTestSupport.textures(from: set.main)
        let output = MetalTestSupport.output(width: 256, height: 144)
        #expect(throws: VideoError.planesTooSmall) {
            try MetalTestSupport.run { commandBuffer in
                try recombiner.encode(
                    main: main, aux: nil, width: 256, height: 144, into: output, commandBuffer: commandBuffer)
            }
        }
    }

    /// VideoToolbox pads the coded picture (108 rows → 112): the stream's own size decides
    /// where aux's V rows start, not the planes' size.
    @Test(arguments: SyntheticFixtures.names)
    func paddedPlanesRecombineTheStream(name: String) throws {
        let set = try SyntheticFixtures.planes(name)
        let (width, height) = (set.main.width, set.main.height)
        let main = MetalTestSupport.textures(from: padded(set.main, rows: 16))
        let aux = MetalTestSupport.textures(from: padded(set.aux, rows: 16))
        let output = MetalTestSupport.output(width: width, height: height)
        try MetalTestSupport.run { commandBuffer in
            try recombiner.encode(
                main: main, aux: aux, width: width, height: height, into: output, commandBuffer: commandBuffer
            )
        }
        #expect(MetalTestSupport.maxDifference(MetalTestSupport.readBGRA(output), set.expected) <= 1)
    }

    @Test func auxSmallerThanTheStreamThrows() throws {
        let big = try SyntheticFixtures.planes("gradient-256x144")
        let small = try SyntheticFixtures.planes("gradient-192x108")
        let output = MetalTestSupport.output(width: 256, height: 144)
        #expect(throws: VideoError.planesTooSmall) {
            try MetalTestSupport.run { commandBuffer in
                try recombiner.encode(
                    main: MetalTestSupport.textures(from: big.main),
                    aux: MetalTestSupport.textures(from: small.aux),
                    width: 256, height: 144, into: output, commandBuffer: commandBuffer)
            }
        }
    }

    /// Sides must be positive and even: a negative one would trap, an odd one leave an edge
    /// unwritten.
    @Test(arguments: [(0, 108), (-2, 108), (191, 108), (192, 107), (192, 0)])
    func badStreamSizesThrow(width: Int, height: Int) throws {
        let set = try SyntheticFixtures.planes("bars-192x108")
        let output = MetalTestSupport.output(width: 192, height: 108)
        #expect(throws: VideoError.streamSize(width: width, height: height)) {
            try MetalTestSupport.run { commandBuffer in
                try recombiner.encode(
                    main: MetalTestSupport.textures(from: set.main), aux: nil, width: width, height: height,
                    into: output, commandBuffer: commandBuffer)
            }
        }
    }

    /// The kernel writes B, G, R, A into `bgra8Unorm`: an sRGB or RGBA output would show
    /// shifted or swapped colours.
    @Test func outputMustBeBGRA8Unorm() throws {
        let set = try SyntheticFixtures.planes("bars-192x108")
        let output = MetalTestSupport.output(width: 192, height: 108, pixelFormat: .rgba8Unorm)
        #expect(throws: VideoError.textureFormat) {
            try MetalTestSupport.run { commandBuffer in
                try recombiner.encode(
                    main: MetalTestSupport.textures(from: set.main), aux: nil, width: 192, height: 108,
                    into: output, commandBuffer: commandBuffer)
            }
        }
    }

    /// `planes` with `rows` more luma rows (and half as many chroma rows) of padding below.
    private func padded(_ planes: NV12Planes, rows: Int) -> NV12Planes {
        NV12Planes(
            width: planes.width, height: planes.height + rows,
            luma: planes.luma + [UInt8](repeating: 235, count: planes.width * rows),
            chroma: planes.chroma + [UInt8](repeating: 16, count: planes.width * rows / 2))
    }

    private func recombine(_ set: PlaneSet, dual: Bool) throws -> [UInt8] {
        let main = MetalTestSupport.textures(from: set.main)
        let aux = dual ? MetalTestSupport.textures(from: set.aux) : nil
        let output = MetalTestSupport.output(width: set.main.width, height: set.main.height)
        try MetalTestSupport.run { commandBuffer in
            try recombiner.encode(
                main: main, aux: aux, width: set.main.width, height: set.main.height, into: output,
                commandBuffer: commandBuffer)
        }
        return MetalTestSupport.readBGRA(output)
    }
}
