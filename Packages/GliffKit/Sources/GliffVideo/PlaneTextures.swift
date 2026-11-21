internal import CoreVideo
internal import Metal

/// A decoded `420v` buffer's planes as Metal textures, without a copy. Holding this keeps the
/// `CVMetalTexture`s, and so the buffer, alive: keep it until the GPU work using it completes.
struct PlaneTextures {
    let textures: NV12Textures
    private let lumaBacking: CVMetalTexture
    private let chromaBacking: CVMetalTexture

    fileprivate init(luma: CVMetalTexture, chroma: CVMetalTexture) throws(VideoError) {
        guard let lumaTexture = CVMetalTextureGetTexture(luma),
            let chromaTexture = CVMetalTextureGetTexture(chroma)
        else { throw .textureCache(kCVReturnError) }
        textures = NV12Textures(luma: lumaTexture, chroma: chromaTexture)
        lumaBacking = luma
        chromaBacking = chroma
    }
}

/// Makes `PlaneTextures` through one `CVMetalTextureCache`.
final class PlaneTextureCache {
    private let cache: CVMetalTextureCache

    init(device: any MTLDevice) throws(VideoError) {
        var cache: CVMetalTextureCache?
        let status = CVMetalTextureCacheCreate(nil, nil, device, nil, &cache)
        guard status == kCVReturnSuccess, let cache else { throw .textureCache(status) }
        self.cache = cache
    }

    /// Lets go of textures for buffers no longer in use (after a stream change).
    func flush() {
        CVMetalTextureCacheFlush(cache, 0)
    }

    func planes(of buffer: CVPixelBuffer) throws(VideoError) -> PlaneTextures {
        try PlaneTextures(
            luma: try texture(buffer, plane: 0, format: .r8Unorm),
            chroma: try texture(buffer, plane: 1, format: .rg8Unorm))
    }

    private func texture(_ buffer: CVPixelBuffer, plane: Int, format: MTLPixelFormat) throws(VideoError)
        -> CVMetalTexture
    {
        var texture: CVMetalTexture?
        let status = CVMetalTextureCacheCreateTextureFromImage(
            nil, cache, buffer, nil, format, CVPixelBufferGetWidthOfPlane(buffer, plane),
            CVPixelBufferGetHeightOfPlane(buffer, plane), plane, &texture)
        guard status == kCVReturnSuccess, let texture else { throw .textureCache(status) }
        return texture
    }
}
