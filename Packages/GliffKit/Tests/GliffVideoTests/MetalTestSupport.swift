import Foundation
import Metal

@testable import GliffVideo

/// Metal plumbing for the video tests: textures from plane bytes, a command buffer run to
/// completion, and BGRA read back.
enum MetalTestSupport {
    static let device: any MTLDevice = MTLCreateSystemDefaultDevice()!
    static let queue = device.makeCommandQueue()!

    static func textures(from planes: NV12Planes) -> NV12Textures {
        NV12Textures(
            luma: texture(.r8Unorm, planes.width, planes.height, bytes: planes.luma, bytesPerPixel: 1),
            chroma: texture(
                .rg8Unorm, planes.width / 2, planes.height / 2, bytes: planes.chroma, bytesPerPixel: 2))
    }

    /// A `bgra8Unorm` texture the GPU writes and the test reads.
    static func output(width: Int, height: Int, pixelFormat: MTLPixelFormat = .bgra8Unorm) -> any MTLTexture {
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: pixelFormat, width: width, height: height, mipmapped: false)
        descriptor.usage = [.shaderRead, .shaderWrite, .renderTarget]
        descriptor.storageMode = .shared
        return device.makeTexture(descriptor: descriptor)!
    }

    /// Encodes with `body`, commits, and waits for the GPU.
    static func run(_ body: (any MTLCommandBuffer) throws -> Void) throws {
        let commandBuffer = queue.makeCommandBuffer()!
        try body(commandBuffer)
        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()
        if let error = commandBuffer.error { throw error }
    }

    static func readBGRA(_ texture: any MTLTexture) -> [UInt8] {
        var bytes = [UInt8](repeating: 0, count: texture.width * texture.height * 4)
        texture.getBytes(
            &bytes, bytesPerRow: texture.width * 4,
            from: MTLRegionMake2D(0, 0, texture.width, texture.height),
            mipmapLevel: 0)
        return bytes
    }

    /// The largest difference between two pictures' bytes; `Int.max` if their sizes differ.
    static func maxDifference(_ a: [UInt8], _ b: [UInt8]) -> Int {
        guard a.count == b.count else { return .max }
        return zip(a, b).lazy.map { abs(Int($0) - Int($1)) }.max() ?? 0
    }

    private static func texture(
        _ format: MTLPixelFormat, _ width: Int, _ height: Int, bytes: [UInt8], bytesPerPixel: Int
    ) -> any MTLTexture {
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: format, width: width, height: height, mipmapped: false)
        descriptor.usage = .shaderRead
        descriptor.storageMode = .shared
        let texture = device.makeTexture(descriptor: descriptor)!
        texture.replace(
            region: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0, withBytes: bytes,
            bytesPerRow: width * bytesPerPixel)
        return texture
    }
}

extension MetalTestSupport {
    /// The BGRA bytes of a private texture, through a blit into a shared one.
    static func readPrivateBGRA(_ texture: any MTLTexture) throws -> [UInt8] {
        let shared = output(width: texture.width, height: texture.height)
        try run { commandBuffer in
            let blit = commandBuffer.makeBlitCommandEncoder()!
            blit.copy(from: texture, to: shared)
            blit.endEncoding()
        }
        return readBGRA(shared)
    }

    /// PSNR in dB over the colour channels of two same-sized BGRA pictures (alpha ignored).
    static func psnr(_ a: [UInt8], _ b: [UInt8]) -> Double {
        guard a.count == b.count, !a.isEmpty else { return 0 }
        var squares = 0.0
        var count = 0
        for index in a.indices where index % 4 != 3 {
            let difference = Double(Int(a[index]) - Int(b[index]))
            squares += difference * difference
            count += 1
        }
        guard squares > 0 else { return .infinity }
        return 10 * log10(255 * 255 / (squares / Double(count)))
    }

    /// `bgra` (`width` pixels a row) moved left by `pixels`, wrapping, as encode-fixtures shifts
    /// frame k by 2k.
    static func shiftedLeft(_ bgra: [UInt8], width: Int, by pixels: Int) -> [UInt8] {
        let row = width * 4
        let split = (pixels % width) * 4
        return stride(from: 0, to: bgra.count, by: row).flatMap { start in
            Array(bgra[start + split..<start + row] + bgra[start..<start + split])
        }
    }
}
