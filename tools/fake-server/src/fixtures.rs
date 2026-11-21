//! Golden fixtures: each case is the CBOR body (no frame header) that upstream gliff-proto
//! v0.4.3 produces for one message. The Swift tests in Packages/GliffKit decode and encode
//! the same values and must match these bytes exactly.

use gliff_proto::{
    Axis, ChromaMode, ClientCaps, ClientMsg, ClipboardFile, ClipboardItem, Codec, OutputInfo, Rect,
    ServerMsg, SessionInfo, VideoPipeline,
};
use crate::wire::body;
use minicbor::Encoder;

/// Every fixture, sorted by name: (name, CBOR body).
pub fn cases() -> Vec<(&'static str, Vec<u8>)> {
    vec![
        ("c00_hello", body(&hello())),
        ("c00b_hello_features", body(&hello_features())),
        ("c01_resize", body(&ClientMsg::Resize { width: 2560, height: 1440, scale: 2.0 })),
        ("c02_key", body(&ClientMsg::Key { keycode: 30, pressed: true })),
        ("c03_pointer_motion", body(&ClientMsg::PointerMotion { x: 1280.5, y: 720.25 })),
        ("c04_pointer_button", body(&ClientMsg::PointerButton { button: 272, pressed: true })),
        (
            "c05_pointer_axis_discrete",
            body(&ClientMsg::PointerAxis { axis: Axis::Vertical, value: -15.0, discrete: Some(-1), stop: false }),
        ),
        (
            "c05b_pointer_axis_smooth",
            body(&ClientMsg::PointerAxis { axis: Axis::Horizontal, value: 3.25, discrete: None, stop: true }),
        ),
        ("c06_frame_ack", body(&ClientMsg::FrameAck { frame_id: 42, decoded_at_ms: 1_700_000_000_123 })),
        ("c07_request_keyframe", body(&ClientMsg::RequestKeyframe)),
        (
            "c08_clipboard_offer",
            body(&ClientMsg::ClipboardOffer { serial: 3, mime_types: offer_mime_types(), files: offer_files() }),
        ),
        (
            "c09_clipboard_request_mime",
            body(&ClientMsg::ClipboardRequest { id: 1, serial: 3, item: ClipboardItem::Mime("image/png".into()) }),
        ),
        (
            "c09b_clipboard_request_file",
            body(&ClientMsg::ClipboardRequest { id: 3, serial: 3, item: ClipboardItem::File(1) }),
        ),
        (
            "c10_clipboard_data",
            body(&ClientMsg::ClipboardData { id: 1, offset: 262_144, data_len: 1024, done: false }),
        ),
        ("c11_ping", body(&ClientMsg::Ping { t: 123_456_789 })),
        ("c12_bye", body(&ClientMsg::Bye)),
        ("c13_clipboard_ack", body(&ClientMsg::ClipboardAck { id: 1, received: 524_288 })),
        ("c14_clipboard_abort", body(&ClientMsg::ClipboardAbort { id: 1 })),
        ("c15_keymap", body(&ClientMsg::Keymap { keymap: "xkb".into() })),
        ("c16_pong", body(&ClientMsg::Pong { t: 987_654_321 })),
        ("s00_hello_ack", body(&hello_ack())),
        ("s01_stream_config_dual", body(&stream_config_dual())),
        (
            "s01b_stream_config_single",
            body(&ServerMsg::StreamConfig {
                codec: Codec::H264,
                chroma: ChromaMode::Single420,
                pipeline: None,
                width: 1280,
                height: 720,
                scale_milli: 500,
                extradata: vec![1, 2],
                aux_extradata: None,
                view_width: 2560,
                view_height: 1440,
                fps_cap: 30,
            }),
        ),
        (
            "s02_video_frame",
            body(&ServerMsg::VideoFrame {
                frame_id: 7,
                pts_us: 116_000,
                keyframe: true,
                damage: vec![Rect { x: 0, y: 0, width: 2560, height: 1440 }],
                data_len: 9000,
                aux_len: 9500,
            }),
        ),
        (
            "s03_cursor_shape",
            body(&ServerMsg::CursorShape { id: 5, width: 24, height: 24, hot_x: 4, hot_y: 2, argb_len: 2304 }),
        ),
        ("s04_cursor_pos", body(&ServerMsg::CursorPos { x: 100.5, y: 200.75, shape_id: 5, visible: true })),
        (
            "s05_clipboard_offer",
            body(&ServerMsg::ClipboardOffer { serial: 3, mime_types: offer_mime_types(), files: offer_files() }),
        ),
        (
            "s06_clipboard_request",
            body(&ServerMsg::ClipboardRequest { id: 2, serial: 9, item: ClipboardItem::File(0) }),
        ),
        ("s07_clipboard_data", body(&ServerMsg::ClipboardData { id: 2, offset: 0, data_len: 4096, done: true })),
        ("s08_pong", body(&ServerMsg::Pong { t: 123_456_789, server_now_ms: 1_700_000_000_999 })),
        ("s09_error", body(&ServerMsg::Error { code: 2, message: "no chroma".into(), version: Some(1) })),
        ("s09b_error_no_version", body(&ServerMsg::Error { code: 256, message: "setup".into(), version: None })),
        ("s10_clipboard_ack", body(&ServerMsg::ClipboardAck { id: 2, received: 4096 })),
        ("s11_clipboard_abort", body(&ServerMsg::ClipboardAbort { id: 2 })),
        ("s12_ping", body(&ServerMsg::Ping { t: 55 })),
        ("x_error_u16_overflow", x_error_u16_overflow()),
        ("x_hello_ack_extra_field", x_hello_ack_extra_field()),
        ("x_stream_config_unknown_chroma", x_stream_config(9, 0)),
        ("x_stream_config_unknown_pipeline", x_stream_config(1, 7)),
        ("x_unknown_variant", x_unknown_variant()),
    ]
}

fn hello() -> ClientMsg {
    ClientMsg::Hello {
        version: 1,
        keymap: "xkb_keymap {}".into(),
        caps: ClientCaps {
            codecs: vec![Codec::H264],
            max_width: 5120,
            max_height: 2880,
            chroma: vec![ChromaMode::Dual420, ChromaMode::Single420],
            features: vec![],
        },
    }
}

/// A Hello whose caps list two codecs and some feature strings, so the text-array encoding
/// is checked with content (v0.4.3's own FEATURES is empty).
fn hello_features() -> ClientMsg {
    ClientMsg::Hello {
        version: 1,
        keymap: "xkb".into(),
        caps: ClientCaps {
            codecs: vec![Codec::H264, Codec::H265],
            max_width: 3840,
            max_height: 2160,
            chroma: vec![ChromaMode::Single420],
            features: vec!["audio".into(), "outputs".into()],
        },
    }
}

fn hello_ack() -> ServerMsg {
    ServerMsg::HelloAck {
        version: 1,
        session: SessionInfo { headless: false, output: "DP-2".into() },
        outputs: vec![output("DP-2"), output("DP-3")],
        features: vec![],
    }
}

fn output(name: &str) -> OutputInfo {
    OutputInfo { name: name.into(), width: 2560, height: 1440, scale_milli: 1000 }
}

fn stream_config_dual() -> ServerMsg {
    ServerMsg::StreamConfig {
        codec: Codec::H264,
        chroma: ChromaMode::Dual420,
        pipeline: Some(VideoPipeline::Gpu),
        width: 2560,
        height: 1440,
        scale_milli: 1000,
        extradata: vec![0, 0, 0, 1, 0x67, 0x64],
        aux_extradata: Some(vec![0, 0, 0, 1, 0x67]),
        view_width: 2560,
        view_height: 1440,
        fps_cap: 60,
    }
}

fn offer_mime_types() -> Vec<String> {
    vec!["text/plain;charset=utf-8".into(), "image/png".into()]
}

/// A file name with accents and an emoji.
fn offer_files() -> Vec<ClipboardFile> {
    vec![
        ClipboardFile { path: "Résumé 📄.txt".into(), size: 12, dir: false },
        ClipboardFile { path: "dir".into(), size: 0, dir: true },
    ]
}

// Hand-built cases: shapes a newer or broken peer could send, which upstream's own types
// can't produce. Each mirrors how minicbor encodes a variant: [index, [fields…]].

/// A message variant this client doesn't know: [99, [1, "x"]].
fn x_unknown_variant() -> Vec<u8> {
    let mut e = Encoder::new(Vec::new());
    e.array(2).unwrap().u32(99).unwrap().array(2).unwrap().u32(1).unwrap().str("x").unwrap();
    e.into_writer()
}

/// HelloAck from a newer server: upstream's own encoding with a fifth field appended.
fn x_hello_ack_extra_field() -> Vec<u8> {
    let mut bytes = body(&hello_ack());
    // [0, [4 fields]]: the inner array head is byte 2.
    assert_eq!(bytes[..3], [0x82, 0x00, 0x84], "HelloAck layout changed upstream");
    bytes[2] = 0x85;
    let mut e = Encoder::new(bytes);
    e.str("future").unwrap();
    e.into_writer()
}

/// `s01_stream_config_dual` with raw chroma (field 1) and pipeline (field 2) indices,
/// to carry values this client doesn't know. Patches upstream's own encoding.
fn x_stream_config(chroma: u8, pipeline: u8) -> Vec<u8> {
    let mut bytes = body(&stream_config_dual());
    // [1, [codec, chroma, pipeline, …]]: each index is one byte while it is below 24.
    assert_eq!(bytes[..6], [0x82, 0x01, 0x8b, 0x01, 0x01, 0x00], "StreamConfig layout changed upstream");
    assert!(chroma < 24 && pipeline < 24);
    bytes[4] = chroma;
    bytes[5] = pipeline;
    bytes
}

/// Error whose `code` (a u16) holds 70000: [9, [70000, "x"]].
fn x_error_u16_overflow() -> Vec<u8> {
    let mut e = Encoder::new(Vec::new());
    e.array(2).unwrap().u32(9).unwrap().array(2).unwrap().u32(70_000).unwrap().str("x").unwrap();
    e.into_writer()
}

#[cfg(test)]
mod tests {
    use super::*;

    /// Sorted keeps the list readable; unique, because a duplicate name would silently
    /// overwrite another fixture's file.
    #[test]
    fn names_are_unique_and_sorted() {
        let names: Vec<&str> = cases().iter().map(|(name, _)| *name).collect();
        let mut sorted = names.clone();
        sorted.sort_unstable();
        sorted.dedup();
        assert_eq!(names, sorted);
    }
}
