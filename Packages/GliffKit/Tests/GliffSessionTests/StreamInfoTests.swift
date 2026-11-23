import GliffInput
import GliffProtocol
import Testing

@testable import GliffSession

struct StreamInfoTests {
    /// What the pointer maps over: the stream's size, its view box and scale, from one config.
    @Test func itsPointerGeometryIsTheConfigs() {
        let info = StreamInfo(
            StreamConfig(
                codec: .h264, chroma: .dual420, pipeline: .gpu, width: 1920, height: 1080, scaleMilli: 1500,
                extradata: [], auxExtradata: nil, viewWidth: 2560, viewHeight: 1440, fpsCap: 60))
        #expect(
            info.pointerGeometry
                == PictureGeometry(
                    streamWidth: 1920, streamHeight: 1080, viewWidth: 2560, viewHeight: 1440, scaleMilli: 1500
                ))
    }
}
