# encode-fixtures

Test tooling. It encodes GliffVideoTests' synthetic planes into small H.264 streams with
VideoToolbox, shaped like gliff-server's: Annex B with 4-byte start codes, the first access
unit `[SPS, PPS, IDR]` with an SPS that has no VUI, then one P slice per frame.

```sh
swift run --package-path tools/encode-fixtures encode-fixtures \
    Packages/GliffKit/Tests/GliffVideoTests/Fixtures/synthetic/planes \
    Packages/GliffKit/Tests/GliffVideoTests/Fixtures/synthetic/streams
```

For each `<name>.main.nv12`/`.aux.nv12` pair it writes `streams/<name>/000…007.{main,aux}.h264`,
one access unit per file. Frame k is the picture shifted left by 2k luma pixels, wrapping, so
its expected BGRA is the plane set's shifted the same way. Single420 tests use the `main` files.

The output is committed. The gate builds and tests the tool but never runs it, because
VideoToolbox's bytes can change between OS releases. Regenerate the streams by hand after the
planes change, and review the diff. The tool refuses to write unless every stream has that
shape, and refuses an output folder that holds anything but stream folders.

Like gliff-server's, the SPS uses picture order count type 0 and, with the VUI gone, carries
no reorder limits. The decoder tests check that each frame comes out before the next goes in.

- `FixtureEncoding`: `H264Encoder` (VTCompressionSession, High, CABAC, real time, no
  reordering, one keyframe), `SPSRewriter` and `BitIO` (strip the VUI), `NV12` and its shift,
  `AccessUnit`.
- `encode-fixtures`: the command line.
- Imports Apple frameworks only: Foundation, VideoToolbox, CoreMedia, CoreVideo,
  Synchronization.
