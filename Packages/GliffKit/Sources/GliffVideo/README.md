# GliffVideo

Owns decoding the video stream into pictures.

- **Imports:** Foundation, `Synchronization`, `os` (Logger), GliffProtocol (the StreamConfig and
  VideoFrame types), Metal, and internally VideoToolbox, CoreMedia (VideoToolbox's sample and
  format types) and CoreVideo. Must not import GliffSession, GliffTransport, AppKit or UIKit.
- **Seam:** `FrameDecoder` (`configure` per coded-stream change, `update` for a StreamConfig
  that keeps the coded stream, `decode` per frame → `DecodeOutcome`). The session awaits each
  decode before it acks the frame.
- `NullFrameDecoder` decodes nothing (`.noPicture`): for session tests that don't need
  pictures.
- `AnnexB` splits each access unit (as gliff-server sends it) into NAL units, pulls out the
  in-band SPS/PPS (`ParameterSets`), and builds the length-prefixed sample VideoToolbox
  decodes.
- `StreamDecoder` decodes one H.264 stream through one VideoToolbox session, synchronously:
  each access unit's `420v` picture comes back from its own call. New in-band parameter sets
  replace the format; an invalid session waits for the next keyframe. An SPS whose cropped
  picture isn't the StreamConfig's size is refused (`streamSize`, a reset), as upstream's
  `check_stream_size` does. A picture VideoToolbox
  holds past its call is no picture, not a reset (a reset would ask for a keyframe on every
  keyframe of a stream it always holds); `VideoToolboxDecoder` logs the first per stream.
- `VideoToolboxDecoder` is the real `FrameDecoder`: both streams through `StreamDecoder`, the
  planes as textures (`PlaneTextures`, no copy), the recombine into a pooled `Picture`, and a
  publish to the `PictureSlot` once the GPU is done. It runs on its own serial queue. With
  every picture in use a frame is still decoded and reports `.noPicture`. The plane-texture
  cache is flushed after each frame's GPU work (or failure), as CoreVideo asks.
- `Picture`/`PicturePool`: at most `poolSize` (3) private `bgra8Unorm` textures per stream size;
  a picture's texture returns to the pool when its last reference goes. Each picture carries
  its stream's remote view and `scaleMilli` (its pool's), so it is never drawn in another
  stream's box and the pointer is mapped with the geometry on screen; a StreamConfig that
  keeps the stream (`update`) moves the stream's pictures, the one on screen too, to the new
  box and scale.
- `PictureSlot` holds the latest picture and a generation count: latest wins, nothing queues.
- `VideoFit`: where the picture goes. 1:1 and centred when it fits the drawable, else scaled
  down with its aspect kept, the limiting side exact; scaled up the same way only with
  Scale to Fit (`scaleToFit`: a smaller mirrored monitor on a larger screen).
  `contentSize` is the window size for actual size, or the largest that fits, in whole
  backing pixels.
- `PictureRenderer` draws a `Picture` into a drawable (`Shaders/Render.metal`): black, then the
  picture stretched to the view box it carries (the server may scale the stream below its view)
  and that box placed by `VideoFit`; nearest-sampled when stream, view and pixels are all 1:1
  (an exact copy), linear otherwise.
  It checks the target's pixel format and holds the picture until the command buffer
  completes. It shares `shaderLibrary(_:)` with `Recombiner`.
- `RedrawTracker`: whether a video view must draw (a new picture, a new drawable size, a
  new view box for the picture on screen, or Scale to Fit toggled).
- `AnnexB` caps an access unit at `maxUnits` NAL units; more is `tooManyUnits`, a reset.
- `Recombiner` turns Dual420 planes (main + aux) or Single420 planes into one BGRA picture
  on the GPU. Its kernel, `Shaders/Recombine.metal`, is a port of upstream Gliff's
  `crates/gliff-vk/shaders/recombine.comp` (MIT; see NOTICE), BT.709 limited range, without
  upstream's `.bgr` swizzle (Metal's `bgra8Unorm` already stores B, G, R, A).
- **Shaders** are `.metal` files compiled at build time, so building needs Apple's Metal
  Toolchain (`xcodebuild -downloadComponent MetalToolchain`).
