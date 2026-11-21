public import Metal
import Synchronization

/// One decoded picture: a `bgra8Unorm` texture of the stream's `width × height`, the remote
/// `view` it shows (the StreamConfig's, which a scaled-down stream is stretched to), and the
/// remote output's `scaleMilli` (pointer positions are divided by it).
///
/// A reader must hold the picture until its own GPU work reading `texture` has completed: once
/// the last reference goes, the texture goes back to its pool and the decoder may write it
/// again on its own queue.
///
/// `@unchecked`: the SDK doesn't mark `MTLTexture` Sendable. A picture is published only after
/// the GPU has finished writing it, and nothing writes it again until it has been recycled, so
/// sharing it for reading is safe.
public final class Picture: @unchecked Sendable {
    public let texture: any MTLTexture
    private let pool: PicturePool

    /// The stream's size, and the remote view it shows: its pool's, one stream's.
    public var width: Int { pool.width }
    public var height: Int { pool.height }
    public var view: PixelSize { pool.view }
    public var scaleMilli: UInt32 { pool.scaleMilli }
    /// The view box and scale read together, so they always come from one StreamConfig.
    public var geometry: (view: PixelSize, scaleMilli: UInt32) { pool.geometry }

    fileprivate init(texture: any MTLTexture, pool: PicturePool) {
        self.texture = texture
        self.pool = pool
    }

    deinit {
        pool.recycle(texture)
    }
}

/// At most `count` picture textures of one size, made as they're first needed and reused,
/// for one stream: its pictures carry its `view` and `scaleMilli`.
final class PicturePool: Sendable {
    let width: Int
    let height: Int
    /// The view box and scale: a StreamConfig that keeps the stream changes them.
    private let geometryState: Mutex<(view: PixelSize, scaleMilli: UInt32)>
    private let count: Int
    private let makeTexture: @Sendable (_ width: Int, _ height: Int) -> (any MTLTexture)?
    private let state = Mutex<(free: [Pooled], made: Int)>(([], 0))

    convenience init(
        device: any MTLDevice, width: Int, height: Int, view: PixelSize? = nil, scaleMilli: UInt32 = 1000,
        count: Int
    ) {
        self.init(width: width, height: height, view: view, scaleMilli: scaleMilli, count: count) {
            width, height in
            let descriptor = MTLTextureDescriptor.texture2DDescriptor(
                pixelFormat: .bgra8Unorm, width: width, height: height, mipmapped: false)
            descriptor.usage = [.shaderRead, .shaderWrite]
            descriptor.storageMode = .private
            return device.makeTexture(descriptor: descriptor)
        }
    }

    /// `view` defaults to the pictures' own size. `makeTexture` is the seam tests use to make
    /// allocation fail.
    init(
        width: Int, height: Int, view: PixelSize? = nil, scaleMilli: UInt32 = 1000, count: Int,
        makeTexture: @escaping @Sendable (_ width: Int, _ height: Int) -> (any MTLTexture)?
    ) {
        self.width = width
        self.height = height
        self.geometryState = Mutex((view ?? PixelSize(width: width, height: height), scaleMilli))
        self.count = count
        self.makeTexture = makeTexture
    }

    /// A free picture, or nil when all `count` are in use. Throws when Metal can't make a texture.
    func acquire() throws(VideoError) -> Picture? {
        // A new texture is made outside the lock, so a picture being dropped on another thread
        // never waits for an allocation.
        let take = state.withLock { state -> Take in
            if let free = state.free.popLast() { return .free(free) }
            guard state.made < count else { return .full }
            state.made += 1
            return .make
        }
        let texture: any MTLTexture
        switch take {
        case .full: return nil
        case .free(let pooled): texture = pooled.texture
        case .make:
            guard let made = makeTexture(width, height) else {
                state.withLock { $0.made -= 1 }
                throw .pictureAllocation
            }
            texture = made
        }
        return Picture(texture: texture, pool: self)
    }

    /// The remote view the stream's pictures fill, and the remote output's scale. A
    /// StreamConfig that keeps the stream changes both, for every picture of the stream, the
    /// one on screen too: the same coded stream, a new box (`update`).
    var geometry: (view: PixelSize, scaleMilli: UInt32) { geometryState.withLock { $0 } }
    var view: PixelSize { geometry.view }
    var scaleMilli: UInt32 { geometry.scaleMilli }

    /// A StreamConfig that keeps the stream: the new box and scale together, in one step.
    func update(view: PixelSize, scaleMilli: UInt32) {
        geometryState.withLock { $0 = (view, scaleMilli) }
    }

    fileprivate func recycle(_ texture: any MTLTexture) {
        let pooled = Pooled(texture: texture)
        state.withLock { $0.free.append(pooled) }
    }
}

/// What `acquire` takes from the pool's state.
private enum Take: Sendable {
    case free(Pooled)
    case make
    case full
}

/// A texture moving in or out of the pool. `@unchecked` as `Picture` is: only a free texture
/// (no picture refers to it, no GPU work pending) is ever in the pool.
private struct Pooled: @unchecked Sendable {
    let texture: any MTLTexture
}
