import Foundation
import Metal

/// GliffVideo's compiled shaders (`Shaders/*.metal`), one library for the module.
func shaderLibrary(_ device: any MTLDevice) throws(VideoError) -> any MTLLibrary {
    do {
        return try device.makeDefaultLibrary(bundle: .module)
    } catch {
        throw .shader("no Metal library: \(error.localizedDescription)")
    }
}
