public import Metal

/// Draws a `Picture` into a drawable (`Shaders/Render.metal`): black, then the picture where
/// `VideoFit.viewport` puts it. Nearest sampling at 1:1, so it is an exact copy; linear when
/// scaled down.
public final class PictureRenderer: Sendable {
    /// The device the renderer's pipeline belongs to: draw with a queue from it.
    public let device: any MTLDevice
    private let pipeline: any MTLRenderPipelineState
    private let nearest: any MTLSamplerState
    private let linear: any MTLSamplerState
    private let pixelFormat: MTLPixelFormat

    public init(device: any MTLDevice, pixelFormat: MTLPixelFormat = .bgra8Unorm) throws(VideoError) {
        self.device = device
        let library = try shaderLibrary(device)
        guard let vertex = library.makeFunction(name: "picture_vertex"),
            let fragment = library.makeFunction(name: "picture_fragment")
        else { throw .shader("no picture shaders") }
        let descriptor = MTLRenderPipelineDescriptor()
        descriptor.vertexFunction = vertex
        descriptor.fragmentFunction = fragment
        descriptor.colorAttachments[0].pixelFormat = pixelFormat
        do {
            pipeline = try device.makeRenderPipelineState(descriptor: descriptor)
        } catch {
            throw .pipeline(error.localizedDescription)
        }
        guard let nearest = Self.sampler(device, filter: .nearest),
            let linear = Self.sampler(device, filter: .linear)
        else { throw .pipeline("no sampler") }
        self.nearest = nearest
        self.linear = linear
        self.pixelFormat = pixelFormat
    }

    /// Encodes the draw of `picture` into `target` (a render target of the renderer's pixel
    /// format). The picture fills the box of the remote view it carries, fitted into the target:
    /// a stream the server scaled below its view is stretched back up to it, as upstream's
    /// client does; with `scaleToFit`, a box smaller than the target is scaled up to fill it.
    /// The command buffer holds `picture` until it completes, so its texture is not recycled
    /// mid-draw.
    public func encode(
        _ picture: Picture, into target: any MTLTexture, commandBuffer: any MTLCommandBuffer,
        scaleToFit: Bool
    ) throws(VideoError) {
        guard target.pixelFormat == pixelFormat else { throw .textureFormat }
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = target
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)
        pass.colorAttachments[0].storeAction = .store
        guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: pass) else {
            throw .commandEncoder
        }
        let view = picture.view
        let fit = VideoFit.viewport(
            picture: view, drawable: PixelSize(width: target.width, height: target.height),
            scaleToFit: scaleToFit)
        // One texel per pixel only when the box is 1:1 and the stream is the view's size.
        let exact = fit.isActualSize && picture.width == view.width && picture.height == view.height
        if fit.width > 0, fit.height > 0 {
            encoder.setRenderPipelineState(pipeline)
            encoder.setViewport(
                MTLViewport(
                    originX: Double(fit.x), originY: Double(fit.y), width: Double(fit.width),
                    height: Double(fit.height), znear: 0, zfar: 1))
            var uvScale = SIMD2<Float>(
                Float(picture.width) / Float(picture.texture.width),
                Float(picture.height) / Float(picture.texture.height))
            encoder.setVertexBytes(&uvScale, length: MemoryLayout<SIMD2<Float>>.stride, index: 0)
            encoder.setFragmentTexture(picture.texture, index: 0)
            encoder.setFragmentSamplerState(exact ? nearest : linear, index: 0)
            encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
        }
        encoder.endEncoding()
        commandBuffer.addCompletedHandler { _ in withExtendedLifetime(picture) {} }
    }

    private static func sampler(_ device: any MTLDevice, filter: MTLSamplerMinMagFilter) -> (
        any MTLSamplerState
    )? {
        let descriptor = MTLSamplerDescriptor()
        descriptor.minFilter = filter
        descriptor.magFilter = filter
        return device.makeSamplerState(descriptor: descriptor)
    }
}
