import Foundation
import Metal

/// One NV12 picture on the GPU, as VideoToolbox's planes map to Metal.
struct NV12Textures {
    /// `r8Unorm`, at least the stream's size.
    let luma: any MTLTexture
    /// `rg8Unorm` (U, V), at least half the stream's size each way.
    let chroma: any MTLTexture
}

/// Turns Dual420 planes (main + aux) or Single420 planes (main) into one BGRA picture on the
/// GPU (`Shaders/Recombine.metal`).
final class Recombiner: Sendable {
    private let pipeline: any MTLComputePipelineState
    /// One SIMD group wide, as tall as the pipeline allows.
    private let threadgroup: MTLSize

    init(device: any MTLDevice) throws(VideoError) {
        let library = try shaderLibrary(device)
        guard let function = library.makeFunction(name: "recombine") else {
            throw .shader("no recombine kernel")
        }
        do {
            pipeline = try device.makeComputePipelineState(function: function)
        } catch {
            throw .pipeline(error.localizedDescription)
        }
        let width = pipeline.threadExecutionWidth
        threadgroup = MTLSize(
            width: width, height: max(1, pipeline.maxTotalThreadsPerThreadgroup / width), depth: 1)
    }

    /// Encodes the recombine of a `width × height` stream (positive, even sides) into `output`
    /// (`bgra8Unorm`, at least that size). `aux == nil` is Single420. The planes may be larger
    /// than the stream (VideoToolbox pads to whole macroblocks).
    func encode(
        main: NV12Textures, aux: NV12Textures?, width: Int, height: Int, into output: any MTLTexture,
        commandBuffer: any MTLCommandBuffer
    ) throws(VideoError) {
        guard width > 0, height > 0, width.isMultiple(of: 2), height.isMultiple(of: 2),
            width <= Int(UInt32.max), height <= Int(UInt32.max)
        else { throw .streamSize(width: width, height: height) }
        // Single420 binds main in aux's slots too: the kernel never reads them.
        let second = aux ?? main
        guard main.hasPlaneFormats, second.hasPlaneFormats, output.pixelFormat == .bgra8Unorm else {
            throw .textureFormat
        }
        guard main.covers(width: width, height: height), second.covers(width: width, height: height),
            output.width >= width, output.height >= height
        else { throw .planesTooSmall }
        guard let encoder = commandBuffer.makeComputeCommandEncoder() else { throw .commandEncoder }
        var params = RecombineParams(width: UInt32(width), height: UInt32(height), hasAux: aux == nil ? 0 : 1)
        encoder.setComputePipelineState(pipeline)
        encoder.setTexture(main.luma, index: 0)
        encoder.setTexture(main.chroma, index: 1)
        encoder.setTexture(second.luma, index: 2)
        encoder.setTexture(second.chroma, index: 3)
        encoder.setTexture(output, index: 4)
        encoder.setBytes(&params, length: MemoryLayout<RecombineParams>.stride, index: 0)
        encoder.dispatchThreads(
            MTLSize(width: width / 2, height: height / 2, depth: 1), threadsPerThreadgroup: threadgroup)
        encoder.endEncoding()
    }
}

/// Mirrors `RecombineParams` in `Shaders/Recombine.metal`: three `uint`s.
private struct RecombineParams {
    var width: UInt32
    var height: UInt32
    var hasAux: UInt32
}

extension NV12Textures {
    fileprivate func covers(width: Int, height: Int) -> Bool {
        luma.width >= width && luma.height >= height && chroma.width >= width / 2
            && chroma.height >= height / 2
    }

    fileprivate var hasPlaneFormats: Bool {
        luma.pixelFormat == .r8Unorm && chroma.pixelFormat == .rg8Unorm
    }
}
