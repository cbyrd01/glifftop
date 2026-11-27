internal import CoreVideo
import Foundation
public import GliffProtocol
public import Metal
import os

/// The real `FrameDecoder`: H.264 through VideoToolbox (one session per Dual420 plane), then
/// the Metal recombine into a pooled BGRA picture, published to `slot` once the GPU is done.
/// It runs on its own serial queue, so VideoToolbox's blocking decode never holds the session
/// actor or the cooperative pool.
public actor VideoToolboxDecoder: FrameDecoder {
    private let queue = DispatchSerialQueue(label: "io.github.cbyrd01.Glifftop.video-decoder")
    private let commandQueue: any MTLCommandQueue
    private let recombiner: Recombiner
    private let textureCache: PlaneTextureCache
    private let device: any MTLDevice
    private let slot: PictureSlot
    private let poolSize: Int
    private let main = StreamDecoder()
    private let aux = StreamDecoder()
    private var stream: (chroma: ChromaMode, pool: PicturePool)?
    /// Whether this stream has logged a held picture: the first says why the screen stays
    /// black, the rest would only repeat it.
    private var loggedHold = false

    private static let log = Logger(subsystem: "io.github.cbyrd01.Glifftop", category: "GliffVideo")

    public nonisolated var unownedExecutor: UnownedSerialExecutor {
        queue.asUnownedSerialExecutor()
    }

    public init(device: any MTLDevice, slot: PictureSlot, poolSize: Int = 3) throws(VideoError) {
        precondition(poolSize >= 1, "a decoder needs at least one picture")
        guard let commandQueue = device.makeCommandQueue() else { throw .commandQueue }
        self.commandQueue = commandQueue
        recombiner = try Recombiner(device: device)
        textureCache = try PlaneTextureCache(device: device)
        self.device = device
        self.slot = slot
        self.poolSize = poolSize
    }

    /// A new coded stream: fresh pictures for its size, and both decoders wait for its IDR.
    public func configure(_ config: StreamConfig) async throws {
        let pool = PicturePool(
            device: device, width: Int(config.width), height: Int(config.height),
            view: config.view, scaleMilli: config.scaleMilli, count: poolSize)
        stream = (config.chroma, pool)
        loggedHold = false
        textureCache.flush()
        for decoder in [main, aux] {
            decoder.invalidate()
            decoder.expectedSize = PixelSize(width: pool.width, height: pool.height)
        }
    }

    /// A kept stream: its pictures fill the new view, at the new scale (decoding goes on
    /// undisturbed).
    public func update(_ config: StreamConfig) async {
        stream?.pool.update(view: config.view, scaleMilli: config.scaleMilli)
    }

    public func decode(
        _ frame: VideoFrameHeader, main mainBytes: ArraySlice<UInt8>, aux auxBytes: ArraySlice<UInt8>
    )
        async -> DecodeOutcome
    {
        guard let stream else { return .failed("no stream configured") }
        // Both planes are always decoded, so neither falls behind on its references.
        var failures: [(plane: String, failure: StreamDecodeFailure)] = []
        var mainBuffer: CVPixelBuffer?
        var auxBuffer: CVPixelBuffer?
        do throws(StreamDecodeFailure) {
            mainBuffer = try main.decode(mainBytes)
        } catch {
            failures.append(("main", error))
        }
        if stream.chroma == .dual420 {
            do throws(StreamDecodeFailure) {
                auxBuffer = try aux.decode(auxBytes)
            } catch {
                failures.append(("aux", error))
            }
        }
        if !loggedHold, let held = failures.first(where: { $0.failure == .held }) {
            loggedHold = true
            Self.log.error("VideoToolbox held a \(held.plane, privacy: .public) picture past its call")
        }
        // A real failure asks for a keyframe; a frame that only gave no picture doesn't.
        if let broken = failures.first(where: { !$0.failure.isNoPicture }) {
            return .failed("\(broken.plane): \(broken.failure)")
        }
        guard failures.isEmpty, let mainBuffer else { return .noPicture }
        let picture: Picture
        do {
            // A frame with no free picture is still decoded above: later frames refer to it.
            guard let free = try stream.pool.acquire() else { return .noPicture }
            picture = free
        } catch {
            return .failed("\(error)")
        }
        do {
            // Then the cache lets go of buffers nothing uses any more (CoreVideo asks for a
            // periodic flush), so VideoToolbox's pool can reuse them: on every path.
            defer { textureCache.flush() }
            let mainPlanes = try textureCache.planes(of: mainBuffer)
            let auxPlanes = try auxBuffer.map { buffer throws(VideoError) in
                try textureCache.planes(of: buffer)
            }
            guard let commandBuffer = commandQueue.makeCommandBuffer() else {
                return .failed("no command buffer")
            }
            try recombiner.encode(
                main: mainPlanes.textures, aux: auxPlanes?.textures, width: picture.width,
                height: picture.height,
                into: picture.texture, commandBuffer: commandBuffer)
            // The session awaits each frame before sending the next, so nothing else runs on
            // this actor while it waits for the GPU.
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                commandBuffer.addCompletedHandler { _ in continuation.resume() }
                commandBuffer.commit()
            }
            // The planes' buffers must outlive the GPU work.
            withExtendedLifetime((mainPlanes, auxPlanes)) {}
            if let error = commandBuffer.error { return .failed("GPU: \(error.localizedDescription)") }
        } catch {
            return .failed("\(error)")
        }
        slot.publish(picture)
        return .picture
    }

    /// Test hook: as if VideoToolbox had invalidated the main session.
    func invalidateMainStreamForTesting() {
        main.invalidate()
    }
}

extension StreamConfig {
    /// The remote view the stream's pictures fill.
    var view: PixelSize { PixelSize(width: Int(viewWidth), height: Int(viewHeight)) }
}
