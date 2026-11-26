//! The server messages scenarios share: HelloAck, and what a client must skip.

use crate::wire::body;
use gliff_proto::{ClipboardFile, OutputInfo, ServerMsg, SessionInfo};

pub(super) fn hello_ack(version: u16, features: &[String]) -> ServerMsg {
    hello_ack_session(version, features, false)
}

pub(super) fn hello_ack_session(version: u16, features: &[String], headless: bool) -> ServerMsg {
    ServerMsg::HelloAck {
        version,
        session: SessionInfo { headless, output: "FAKE-1".into() },
        outputs: vec![OutputInfo { name: "FAKE-1".into(), width: 1280, height: 720, scale_milli: 1000 }],
        features: features.to_vec(),
    }
}

/// Messages (body, payload) a v0.4.3 server can send mid-stream that the client must skip
/// or ignore.
pub(super) fn skippable() -> Vec<(Vec<u8>, Vec<u8>)> {
    vec![
        (
            body(&ServerMsg::CursorShape { id: 1, width: 2, height: 2, hot_x: 0, hot_y: 0, argb_len: 16 }),
            vec![0xFF; 16],
        ),
        (body(&ServerMsg::CursorPos { x: 10.5, y: 20.0, shape_id: 1, visible: true }), vec![]),
        (
            body(&ServerMsg::ClipboardOffer {
                serial: 1,
                mime_types: vec!["text/plain".into()],
                files: Vec::<ClipboardFile>::new(),
            }),
            vec![],
        ),
        (body(&ServerMsg::ClipboardData { id: 2, offset: 0, data_len: 5, done: true }), b"hello".to_vec()),
        (body(&ServerMsg::Pong { t: 0, server_now_ms: super::now_ms() }), vec![]),
        // [77, []]: a variant no v0.4.3 client knows.
        (vec![0x82, 0x18, 77, 0x80], vec![1, 2, 3, 4]),
    ]
}
