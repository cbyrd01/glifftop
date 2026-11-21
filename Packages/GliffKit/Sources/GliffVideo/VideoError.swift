/// Why the video pipeline couldn't be set up, or couldn't take a frame.
public enum VideoError: Error, Equatable, Sendable {
    case noMetalDevice
    /// The bundled Metal library or a function in it is missing.
    case shader(String)
    case pipeline(String)
    /// A stream size the GPU can't take: each side must be positive and even.
    case streamSize(width: Int, height: Int)
    /// The planes handed to the GPU are smaller than the stream they claim to be.
    case planesTooSmall
    /// A texture of the wrong pixel format: planes `r8Unorm`/`rg8Unorm`, pictures `bgra8Unorm`.
    case textureFormat
    /// Metal gave no command encoder (the command buffer is unusable).
    case commandEncoder
    /// Metal couldn't make a picture texture.
    case pictureAllocation
    /// Metal gave no command queue.
    case commandQueue
    /// CoreVideo couldn't make a texture cache, or a texture from a decoded picture.
    case textureCache(Int32)
}
