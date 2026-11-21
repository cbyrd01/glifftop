import GliffProtocol
import Metal
import Testing

@testable import GliffVideo

struct VideoToolboxDecoderTests {
    /// Encoded at VideoToolbox quality 0.95: every picture must come within this of upstream's.
    static let minimumPSNR = 35.0

    @Test(arguments: ["bars-192x108", "gradient-192x108"])
    func dualDecodeMatchesExpected(name: String) async throws {
        let planes = try SyntheticFixtures.planes(name)
        let (main, aux) = try Self.streams(name)
        let slot = PictureSlot()
        let decoder = try await Self.decoder(.dual420, planes, slot: slot)
        for frame in main.indices {
            #expect(await Self.decode(decoder, main: main[frame], aux: aux[frame]) == .picture)
            let latest = try #require(slot.latest)
            #expect(latest.generation == UInt64(frame + 1))
            let expected = MetalTestSupport.shiftedLeft(
                planes.expected, width: planes.main.width, by: 2 * frame)
            let psnr = MetalTestSupport.psnr(try Self.pixels(latest.picture), expected)
            #expect(psnr >= Self.minimumPSNR, "frame \(frame): \(psnr) dB")
        }
    }

    @Test func singleDecodeMatchesExpected() async throws {
        let planes = try SyntheticFixtures.planes("gradient-192x108")
        let (main, _) = try Self.streams("gradient-192x108")
        let slot = PictureSlot()
        let decoder = try await Self.decoder(.single420, planes, slot: slot)
        for frame in main.indices {
            #expect(await Self.decode(decoder, main: main[frame], aux: []) == .picture)
            let expected = MetalTestSupport.shiftedLeft(
                planes.expectedSingle, width: planes.main.width, by: 2 * frame)
            let psnr = MetalTestSupport.psnr(try Self.pixels(try #require(slot.latest).picture), expected)
            #expect(psnr >= Self.minimumPSNR, "frame \(frame): \(psnr) dB")
        }
    }

    /// The point of Dual420: fine chroma survives that Single420 loses.
    @Test func dualKeepsFineChromaThatSingleLoses() async throws {
        let planes = try SyntheticFixtures.planes("fine-192x108")
        let (main, aux) = try Self.streams("fine-192x108")
        let dualSlot = PictureSlot()
        let singleSlot = PictureSlot()
        let dual = try await Self.decoder(.dual420, planes, slot: dualSlot)
        let single = try await Self.decoder(.single420, planes, slot: singleSlot)
        #expect(await Self.decode(dual, main: main[0], aux: aux[0]) == .picture)
        #expect(await Self.decode(single, main: main[0], aux: []) == .picture)
        let dualPSNR = MetalTestSupport.psnr(
            try Self.pixels(try #require(dualSlot.latest).picture), planes.expected)
        let singlePSNR = MetalTestSupport.psnr(
            try Self.pixels(try #require(singleSlot.latest).picture), planes.expected)
        #expect(dualPSNR - singlePSNR >= 6, "dual \(dualPSNR) dB, single \(singlePSNR) dB")
    }

    @Test func firstFrameWithoutKeyframeFails() async throws {
        let (main, aux) = try Self.streams("bars-192x108")
        let decoder = try await Self.decoder(.dual420, try SyntheticFixtures.planes("bars-192x108"))
        #expect(await Self.isFailure(Self.decode(decoder, main: main[1], aux: aux[1])))
        #expect(await Self.decode(decoder, main: main[0], aux: aux[0]) == .picture)
    }

    @Test func auxFailureFailsTheFrame() async throws {
        let (main, aux) = try Self.streams("bars-192x108")
        let slot = PictureSlot()
        let decoder = try await Self.decoder(
            .dual420, try SyntheticFixtures.planes("bars-192x108"), slot: slot)
        #expect(await Self.isFailure(Self.decode(decoder, main: main[0], aux: aux[1])))
        #expect(slot.latest == nil)
    }

    /// A frame VideoToolbox gives no picture for (here: no slices) breaks nothing: `.noPicture`,
    /// no keyframe request, and the stream carries on.
    @Test func frameWithoutSlicesIsNoPicture() async throws {
        let (main, aux) = try Self.streams("bars-192x108")
        let decoder = try await Self.decoder(.dual420, try SyntheticFixtures.planes("bars-192x108"))
        #expect(await Self.decode(decoder, main: main[0], aux: aux[0]) == .picture)
        let empty = await Self.decode(
            decoder, main: StreamDecoderTests.parameterSetsOnly(main[0]),
            aux: StreamDecoderTests.parameterSetsOnly(aux[0]))
        #expect(empty == .noPicture)
        #expect(await Self.decode(decoder, main: main[1], aux: aux[1]) == .picture)
    }

    /// Decoded planes smaller than the configured stream: the recombine refuses them.
    @Test func streamSmallerThanConfigFails() async throws {
        let (main, aux) = try Self.streams("bars-192x108")
        let decoder = try await Self.decoder(.dual420, try SyntheticFixtures.planes("gradient-256x144"))
        #expect(await Self.isFailure(Self.decode(decoder, main: main[0], aux: aux[0])))
    }

    /// An in-band SPS for a bigger picture than the StreamConfig's is refused, not cropped
    /// (upstream's `check_stream_size`): a failure that resets, so the next IDR must be right.
    @Test func streamLargerThanConfigFails() async throws {
        let (main, aux) = try Self.streams("gradient-256x144")
        let (rightMain, rightAux) = try Self.streams("bars-192x108")
        let decoder = try await Self.decoder(.dual420, try SyntheticFixtures.planes("bars-192x108"))
        #expect(await Self.isFailure(Self.decode(decoder, main: main[0], aux: aux[0])))
        #expect(await Self.decode(decoder, main: rightMain[0], aux: rightAux[0]) == .picture)
    }

    /// With every picture in use the frame is still decoded (later frames need it), reports
    /// `.noPicture` at once, and the next frame after a release has a picture again.
    @Test(.timeLimit(.minutes(1)))
    func exhaustedPoolDropsWithoutBlocking() async throws {
        let (main, aux) = try Self.streams("bars-192x108")
        let slot = PictureSlot()
        let decoder = try await Self.decoder(
            .dual420, try SyntheticFixtures.planes("bars-192x108"), slot: slot, poolSize: 2)
        #expect(await Self.decode(decoder, main: main[0], aux: aux[0]) == .picture)
        var held: Picture? = try #require(slot.latest).picture
        #expect(await Self.decode(decoder, main: main[1], aux: aux[1]) == .picture)
        let start = ContinuousClock.now
        #expect(await Self.decode(decoder, main: main[2], aux: aux[2]) == .noPicture)
        #expect(ContinuousClock.now - start < .seconds(1))
        #expect(held != nil)
        held = nil
        #expect(await Self.decode(decoder, main: main[3], aux: aux[3]) == .picture)
    }

    @Test func configureResizes() async throws {
        let slot = PictureSlot()
        let small = try SyntheticFixtures.planes("bars-192x108")
        let decoder = try await Self.decoder(.dual420, small, slot: slot)
        let (main, aux) = try Self.streams("bars-192x108")
        #expect(await Self.decode(decoder, main: main[0], aux: aux[0]) == .picture)
        #expect(try #require(slot.latest).picture.width == 192)
        try await decoder.configure(Self.config(.dual420, width: 256, height: 144))
        let (largeMain, largeAux) = try Self.streams("gradient-256x144")
        #expect(await Self.decode(decoder, main: largeMain[0], aux: largeAux[0]) == .picture)
        let picture = try #require(slot.latest).picture
        #expect(picture.width == 256 && picture.height == 144)
        #expect(picture.texture.width == 256 && picture.texture.height == 144)
    }

    /// Each picture carries the remote view of the StreamConfig it was decoded under, so a
    /// view drawing it never pairs it with another stream's box.
    @Test func pictureCarriesTheStreamsView() async throws {
        let slot = PictureSlot()
        let planes = try SyntheticFixtures.planes("bars-192x108")
        let decoder = try await Self.decoder(.dual420, planes, slot: slot)
        let (main, aux) = try Self.streams("bars-192x108")
        #expect(await Self.decode(decoder, main: main[0], aux: aux[0]) == .picture)
        #expect(try #require(slot.latest).picture.view == PixelSize(width: 192, height: 108))
        try await decoder.configure(
            Self.config(
                .dual420, width: 192, height: 108, view: PixelSize(width: 384, height: 216), scaleMilli: 1500)
        )
        #expect(await Self.decode(decoder, main: main[0], aux: aux[0]) == .picture)
        #expect(try #require(slot.latest).picture.geometry == (PixelSize(width: 384, height: 216), 1500))
    }

    /// A view-only change keeps decoding (the next P frame still gives a picture), and the
    /// stream's pictures, the one on screen included, fill the new view's box.
    @Test func viewUpdateKeepsDecodingInTheNewBox() async throws {
        let slot = PictureSlot()
        let planes = try SyntheticFixtures.planes("bars-192x108")
        let decoder = try await Self.decoder(.dual420, planes, slot: slot)
        let (main, aux) = try Self.streams("bars-192x108")
        #expect(await Self.decode(decoder, main: main[0], aux: aux[0]) == .picture)
        let shown = try #require(slot.latest).picture
        let view = PixelSize(width: 384, height: 216)
        await decoder.update(Self.config(.dual420, width: 192, height: 108, view: view, scaleMilli: 2000))
        #expect(shown.geometry == (view, 2000))
        #expect(await Self.decode(decoder, main: main[1], aux: aux[1]) == .picture)
        #expect(try #require(slot.latest).picture.view == view)
    }

    @Test func recoversAfterTheSessionDies() async throws {
        let (main, aux) = try Self.streams("bars-192x108")
        let decoder = try await Self.decoder(.dual420, try SyntheticFixtures.planes("bars-192x108"))
        #expect(await Self.decode(decoder, main: main[0], aux: aux[0]) == .picture)
        await decoder.invalidateMainStreamForTesting()
        #expect(await Self.isFailure(Self.decode(decoder, main: main[1], aux: aux[1])))
        #expect(await Self.decode(decoder, main: main[0], aux: aux[0]) == .picture)
    }

    // MARK: - Helpers

    private static func streams(_ name: String) throws -> (main: [[UInt8]], aux: [[UInt8]]) {
        (try SyntheticFixtures.stream(name, plane: .main), try SyntheticFixtures.stream(name, plane: .aux))
    }

    private static func decoder(
        _ chroma: ChromaMode, _ planes: PlaneSet, slot: PictureSlot = PictureSlot(), poolSize: Int = 3
    ) async throws -> VideoToolboxDecoder {
        let decoder = try VideoToolboxDecoder(device: MetalTestSupport.device, slot: slot, poolSize: poolSize)
        try await decoder.configure(config(chroma, width: planes.main.width, height: planes.main.height))
        return decoder
    }

    private static func config(
        _ chroma: ChromaMode, width: Int, height: Int, view: PixelSize? = nil, scaleMilli: UInt32 = 1000
    ) -> StreamConfig {
        StreamConfig(
            codec: .h264, chroma: chroma, pipeline: nil, width: UInt32(width), height: UInt32(height),
            scaleMilli: scaleMilli, extradata: [], auxExtradata: nil, viewWidth: UInt32(view?.width ?? width),
            viewHeight: UInt32(view?.height ?? height), fpsCap: 60)
    }

    /// One frame, with main and aux as slices of one payload (aux not starting at 0), as the
    /// session hands them over.
    private static func decode(_ decoder: VideoToolboxDecoder, main: [UInt8], aux: [UInt8]) async
        -> DecodeOutcome
    {
        let payload = main + aux
        let header = VideoFrameHeader(
            frameID: 1, ptsMicroseconds: 0, isKeyframe: false, damage: [], dataLength: UInt32(main.count),
            auxLength: UInt32(aux.count))
        return await decoder.decode(header, main: payload[..<main.count], aux: payload[main.count...])
    }

    private static func isFailure(_ outcome: DecodeOutcome) -> Bool {
        if case .failed = outcome { true } else { false }
    }

    private static func pixels(_ picture: Picture) throws -> [UInt8] {
        try MetalTestSupport.readPrivateBGRA(picture.texture)
    }
}
