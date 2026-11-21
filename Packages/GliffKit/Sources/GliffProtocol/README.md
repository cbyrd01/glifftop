# GliffProtocol

Owns Gliff wire format v1: the frame header, a minimal CBOR reader and writer, and the
client and server message types.

- **Pure:** imports Foundation only. No I/O, no AppKit or UIKit, no other GliffKit module.
- **Source of truth:** upstream `gliff-proto` at v0.4.3 (`msg.rs`, `frame.rs`,
  `clipboard.rs`). Golden fixtures generated from that code by `tools/fake-server` check the
  encoding byte for byte.

## Public API

- `ServerMessage.decode(_:)` turns a frame body into a `ServerMessage`; `ClientMessage.encoded`
  is a frame body to send; `FrameHeader` is the 8-byte header and its limits. Plus the value
  types they carry, `GliffProtocol.version`/`.features`, `ErrorCode` and `ProtocolError`.
- `FrameParser` splits a byte stream into `Frame`s (body + payload), however it is chunked,
  failing on the first bad header; `Frame.encode(body:payload:)` builds a frame to send.
  `ServerMessage.checkPayload(carried:)` applies upstream's payload rules: each declared
  section at most 64 MiB, together no more than the frame carries (fewer is fine; the rest
  is skipped). A malformed cursor shape (`CursorShape.payloadFits`) declares nothing.
- Internal: `CBORReader`, `CBORWriter` and `FieldReader` (minicbor's field-list rules).

## Encoding rules (minicbor, as upstream v0.4.3 writes them)

Checked against the golden fixtures in `Tests/GliffProtocolTests/Fixtures`.

- **Message:** `[variant index, [fields…]]`. A variant with no fields is `[index, []]`
  (`c07_request_keyframe` = `82 07 80`).
- **Struct:** an array of its fields in `#[n(…)]` order (`ClientCaps`, `Rect`, `OutputInfo`).
- **`index_only` enum** (`Codec`, `ChromaMode`, `VideoPipeline`, `Axis`): a bare uint.
  An enum with data (`ClipboardItem`) is `[index, [fields…]]`, like a message.
- **Integers:** the shortest head, whatever the Rust type.
- **Floats:** the Rust type's width, never shortened: `f32` as `fa`, `f64` as `fb`.
- **`Option::None`:** `null` (`f6`) in the middle of a field list. Trailing `None` fields
  are left out, so the array is shorter (`s09b_error_no_version` has 2 fields, not 3).
- **Byte fields** (`extradata`): a CBOR byte string. **Text:** UTF-8 text string.

## Decoding rules (what a v1 client must accept)

- A message, and an enum with data, is exactly a definite two-element array
  `[variant, fields]`; anything else is an error (minicbor derive). Variant and enum indices
  are read as `i64`: a negative one is unknown, one beyond `i64` is an error.
- Unknown message variant: skip the message and its payload without reading its fields,
  even if they are malformed (upstream `gliff-transport` `is_unknown_message`: the unknown
  index is the one right after the outer array head).
- An integer that doesn't fit its field's type fails the message, never truncated or
  clamped (`x_error_u16_overflow`: `Error.code` is a `u16` holding 70000).
- Fewer fields than the type has: the missing trailing fields are `None`; a missing
  required field is an error. More fields than the type has: ignore the extras.
- An unknown value in an optional enum field (`StreamConfig.pipeline`) decodes as `None`
  (upstream `cbor::optional`). In a required enum field (`StreamConfig.chroma`) it is an
  error, and upstream's transport closes the connection.
- Lists a peer uses to describe itself (`ClientCaps.codecs`, `.chroma`) drop unknown
  entries instead of failing (upstream `cbor::known`).
