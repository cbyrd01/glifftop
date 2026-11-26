//! The serve scenarios, run against scripted clients over in-memory streams.

use super::*;
use crate::wire::{read_frame, Frame};
use std::io::Cursor;

pub(super) fn try_options(args: &[&str]) -> Result<Options, String> {
    parse(&args.iter().map(|a| a.to_string()).collect::<Vec<_>>())
}

pub(super) fn options(args: &[&str]) -> Options {
    try_options(args).unwrap()
}

fn client(messages: &[ClientMsg]) -> Cursor<Vec<u8>> {
    let mut bytes = Vec::new();
    for message in messages {
        write_frame(&mut bytes, &body(message), &[]).unwrap();
    }
    Cursor::new(bytes)
}

pub(super) fn hello(features: &[&str]) -> ClientMsg {
    ClientMsg::Hello {
        version: 1,
        keymap: String::new(),
        caps: gliff_proto::ClientCaps {
            codecs: vec![Codec::H264],
            max_width: 4096,
            max_height: 2880,
            chroma: vec![ChromaMode::Dual420, ChromaMode::Single420],
            features: features.iter().map(|f| f.to_string()).collect(),
        },
    }
}

pub(super) fn ack(frame_id: u64) -> ClientMsg {
    ClientMsg::FrameAck { frame_id, decoded_at_ms: 0 }
}

/// What the server wrote, as frames.
pub(super) fn sent(bytes: Vec<u8>) -> Vec<Frame> {
    let mut input = Cursor::new(bytes);
    std::iter::from_fn(|| read_frame(&mut input).unwrap()).collect()
}

pub(super) fn decoded(frames: &[Frame]) -> Vec<ServerMsg> {
    frames.iter().filter_map(|f| minicbor::decode(&f.body).ok()).collect()
}

#[test]
fn parses_flags() {
    let parsed = options(&["stream", "--chroma", "single", "--frames", "30", "--expect-bye"]);
    assert_eq!(parsed.scenario, Scenario::Stream);
    assert_eq!(parsed.chroma, ChromaMode::Single420);
    assert_eq!(parsed.frames, Some(30));
    assert!(parsed.expect_bye);
    assert_eq!(options(&["error", "256"]).scenario, Scenario::Error(256));
    assert_eq!(options(&["feature", "--feature", "b", "--feature", "a"]).features, ["b", "a"]);
    assert!(try_options(&["nope"]).is_err());
    assert!(try_options(&["stream", "--frames"]).is_err());
}

#[test]
fn handshake_sends_hello_ack() {
    let mut out = Vec::new();
    run(&options(&["handshake"]), client(&[hello(&[]), ClientMsg::Bye]), &mut out).unwrap();
    assert!(matches!(decoded(&sent(out))[..], [ServerMsg::HelloAck { version: 1, .. }]));
}

#[test]
fn wrong_hello_fails() {
    let mut bad = hello(&[]);
    if let ClientMsg::Hello { caps, .. } = &mut bad {
        caps.chroma = vec![ChromaMode::Single420];
    }
    let error = run(&options(&["handshake"]), client(&[bad]), Vec::new()).unwrap_err();
    assert!(error.contains("chroma"), "{error}");
}

#[test]
fn stream_with_every_ack_passes() {
    let mut out = Vec::new();
    let input = client(&[hello(&[]), ack(1), ack(2), ack(3), ClientMsg::Bye]);
    run(&options(&["stream", "--frames", "3", "--expect-bye"]), input, &mut out).unwrap();
    let frames = sent(out);
    let messages = decoded(&frames);
    assert!(matches!(messages[1], ServerMsg::StreamConfig { chroma: ChromaMode::Dual420, width: 1280, .. }));
    let ids: Vec<(u64, bool)> = messages
        .iter()
        .filter_map(|m| match m {
            ServerMsg::VideoFrame { frame_id, keyframe, data_len: 1000, aux_len: 500, .. } => {
                Some((*frame_id, *keyframe))
            }
            _ => None,
        })
        .collect();
    assert_eq!(ids, [(1, true), (2, false), (3, false)]);
    assert_eq!(frames[2].payload.len(), 1500);
}

#[test]
fn missing_ack_fails() {
    let input = client(&[hello(&[]), ack(1), ack(2)]);
    let error = run(&options(&["stream", "--frames", "3"]), input, Vec::new()).unwrap_err();
    assert!(error.contains("frame 3"), "{error}");
}

#[test]
fn missing_bye_fails_when_expected() {
    let input = client(&[hello(&[]), ack(1)]);
    let error = run(&options(&["stream", "--frames", "1", "--expect-bye"]), input, Vec::new()).unwrap_err();
    assert!(error.contains("Bye"), "{error}");
}

#[test]
fn client_ping_is_answered() {
    let mut out = Vec::new();
    let input = client(&[hello(&[]), ClientMsg::Ping { t: 5 }, ack(1)]);
    run(&options(&["stream", "--frames", "1"]), input, &mut out).unwrap();
    assert!(decoded(&sent(out)).iter().any(|m| matches!(m, ServerMsg::Pong { t: 5, .. })));
}

#[test]
fn ping_first_needs_a_pong_first() {
    let input = client(&[hello(&[]), ack(1)]);
    let error = run(&options(&["ping-first"]), input, Vec::new()).unwrap_err();
    assert!(error.contains("Pong"), "{error}");
    let input = client(&[hello(&[]), ClientMsg::Pong { t: 42 }, ack(1), ack(2), ack(3)]);
    run(&options(&["ping-first"]), input, Vec::new()).unwrap();
}

/// Upstream skips a client message whose variant it doesn't know, payload and all.
#[test]
fn unknown_client_message_is_skipped() {
    let mut input = client(&[hello(&[])]).into_inner();
    write_frame(&mut input, &[0x82, 0x18, 99, 0x80], &[&[1, 2, 3]]).unwrap();
    input.extend(client(&[ack(1)]).into_inner());
    run(&options(&["stream", "--frames", "1"]), Cursor::new(input), Vec::new()).unwrap();
}

#[test]
fn malformed_client_message_fails() {
    let mut input = client(&[hello(&[])]).into_inner();
    write_frame(&mut input, &[0xff], &[]).unwrap();
    let error = run(&options(&["stream", "--frames", "1"]), Cursor::new(input), Vec::new()).unwrap_err();
    assert!(error.contains("undecodable"), "{error}");
}

/// Upstream pipelines Ping behind HelloAck and streams without waiting for the Pong.
#[test]
fn ping_first_streams_before_the_pong() {
    let mut out = Vec::new();
    let error = run(&options(&["ping-first"]), client(&[hello(&[])]), &mut out).unwrap_err();
    assert!(error.contains("Pong"), "{error}");
    assert_eq!(sent(out).len(), 6); // HelloAck, Ping, StreamConfig, 3 frames
}

#[test]
fn silent_still_checks_the_hello() {
    let error = run(&options(&["silent"]), client(&[]), Vec::new()).unwrap_err();
    assert!(error.contains("Hello"), "{error}");
    run(&options(&["silent"]), client(&[hello(&[])]), Vec::new()).unwrap();
}

#[test]
fn mid_frame_drop_ends_inside_frame_three() {
    let mut out = Vec::new();
    run(&options(&["drop", "--mid-frame"]), client(&[hello(&[])]), &mut out).unwrap();
    let mut input = Cursor::new(out);
    let mut complete = 0;
    let error = loop {
        match read_frame(&mut input) {
            Ok(Some(_)) => complete += 1,
            Ok(None) => panic!("ended cleanly"),
            Err(error) => break error,
        }
    };
    assert_eq!(complete, 4); // HelloAck, StreamConfig, frames 1 and 2
    assert_eq!(error.kind(), std::io::ErrorKind::UnexpectedEof);
}

#[test]
fn config_change_keeps_counting_frames() {
    let acks: Vec<ClientMsg> = (1..=9).map(ack).collect();
    let input = client(&[vec![hello(&[])], acks].concat());
    let mut out = Vec::new();
    run(&options(&["config-change"]), input, &mut out).unwrap();
    let configs: Vec<(u32, u32)> = decoded(&sent(out))
        .iter()
        .filter_map(|m| match m {
            ServerMsg::StreamConfig { width, fps_cap, .. } => Some((*width, *fps_cap)),
            _ => None,
        })
        .collect();
    assert_eq!(configs, [(1280, 60), (1280, 30), (1920, 30)]);
}

#[test]
fn feature_echoes_and_sends_unknown_variants() {
    let input = client(&[hello(&["test-feature"]), ack(1), ack(2)]);
    let mut out = Vec::new();
    run(&options(&["feature", "--feature", "test-feature"]), input, &mut out).unwrap();
    let frames = sent(out);
    assert_eq!(frames[1].body, [0x82, 0x18, 99, 0x81, 7]);
    assert_eq!(frames[1].payload, [1, 2, 3]);
    assert_eq!(frames[2].payload.len(), 2);
}

#[test]
fn bye_mid_stream_ends_cleanly_when_expected() {
    // A client that disconnects mid-stream never sees the frames still in flight: upstream's
    // server just ends, so the fake does too, once the acks so far were in order.
    let mut out = Vec::new();
    let input = client(&[hello(&[]), ack(1), ClientMsg::Bye]);
    run(&options(&["stream", "--frames", "1000", "--expect-bye"]), input, &mut out).unwrap();
    let frames = decoded(&sent(out)).iter().filter(|m| matches!(m, ServerMsg::VideoFrame { .. })).count();
    assert_eq!(frames, 5);
}

#[test]
fn bye_mid_stream_fails_when_not_expected() {
    let input = client(&[hello(&[]), ack(1), ClientMsg::Bye]);
    let error = run(&options(&["stream", "--frames", "1000"]), input, Vec::new()).unwrap_err();
    assert!(error.contains("Bye"), "{error}");
}

#[test]
fn bye_after_the_last_frame_still_needs_every_ack() {
    let input = client(&[hello(&[]), ack(1), ClientMsg::Bye]);
    let error = run(&options(&["stream", "--frames", "3", "--expect-bye"]), input, Vec::new()).unwrap_err();
    assert!(error.contains("frame 2"), "{error}");
}

/// A scratch streams folder: `count` frames of distinct bytes, with aux files if `aux`.
fn streams_dir(name: &str, count: usize, aux: bool) -> std::path::PathBuf {
    let dir = std::env::temp_dir().join(format!("glifftop-fake-server-{name}-{}", std::process::id()));
    let _ = std::fs::remove_dir_all(&dir);
    std::fs::create_dir_all(&dir).unwrap();
    for i in 0..count {
        std::fs::write(dir.join(format!("{i:03}.main.h264")), vec![i as u8; 10 + i]).unwrap();
        if aux {
            std::fs::write(dir.join(format!("{i:03}.aux.h264")), vec![0x80 | i as u8; 5 + i]).unwrap();
        }
    }
    dir
}

/// (frame id, keyframe, data_len, aux_len, payload) of each VideoFrame sent.
fn video_frames(out: Vec<u8>) -> Vec<(u64, bool, u32, u32, Vec<u8>)> {
    sent(out)
        .into_iter()
        .filter_map(|frame| match minicbor::decode(&frame.body) {
            Ok(ServerMsg::VideoFrame { frame_id, keyframe, data_len, aux_len, .. }) => {
                Some((frame_id, keyframe, data_len, aux_len, frame.payload))
            }
            _ => None,
        })
        .collect()
}

#[test]
fn streams_replay_in_order_with_one_keyframe() {
    let dir = streams_dir("dual", 3, true);
    let mut out = Vec::new();
    let input = client(&[hello(&[]), ack(1), ack(2), ack(3), ClientMsg::Bye]);
    let args = ["stream", "--streams", dir.to_str().unwrap(), "--size", "192x108", "--expect-bye"];
    run(&options(&args), input, &mut out).unwrap();
    let messages = decoded(&sent(out.clone()));
    assert!(matches!(messages[1], ServerMsg::StreamConfig { width: 192, height: 108, view_width: 192, .. }));
    let expected: Vec<_> = (0..3u8)
        .map(|i| {
            let (main, aux) = (vec![i; 10 + i as usize], vec![0x80 | i; 5 + i as usize]);
            (u64::from(i) + 1, i == 0, main.len() as u32, aux.len() as u32, [main, aux].concat())
        })
        .collect();
    assert_eq!(video_frames(out), expected);
    std::fs::remove_dir_all(&dir).unwrap();
}

#[test]
fn single_sends_no_aux() {
    let dir = streams_dir("single", 3, false);
    let mut out = Vec::new();
    let input = client(&[hello(&[]), ack(1), ack(2)]);
    let args = ["stream", "--chroma", "single", "--streams", dir.to_str().unwrap(), "--frames", "2"];
    run(&options(&args), input, &mut out).unwrap();
    let frames = video_frames(out);
    assert_eq!(frames.len(), 2);
    assert_eq!(frames[1], (2, false, 11, 0, vec![1; 11]));
    std::fs::remove_dir_all(&dir).unwrap();
}

#[test]
fn missing_streams_dir_is_usage_error() {
    assert!(try_options(&["stream", "--streams", "/nonexistent/glifftop-streams"]).is_err());
    // Dual420 needs every aux file.
    let main_only = streams_dir("main-only", 2, false);
    let dir = main_only.to_str().unwrap();
    assert!(try_options(&["stream", "--streams", dir]).is_err());
    assert!(try_options(&["stream", "--chroma", "single", "--streams", dir]).is_ok());
    // Only the stream scenario replays streams.
    assert!(try_options(&["handshake", "--chroma", "single", "--streams", dir]).is_err());
    assert!(try_options(&["stream", "--size", "192"]).is_err());
    std::fs::remove_dir_all(&main_only).unwrap();
}

#[test]
fn bad_stream_options_are_usage_errors() {
    let streams = streams_dir("bad-options", 2, true);
    let dir = streams.to_str().unwrap();
    // More frames than files, a size of nothing, a size outside the stream scenario.
    assert!(try_options(&["stream", "--streams", dir, "--frames", "3"]).is_err());
    assert!(try_options(&["stream", "--streams", dir, "--frames", "2"]).is_ok());
    assert!(try_options(&["stream", "--size", "0x108"]).is_err());
    assert!(try_options(&["handshake", "--size", "192x108"]).is_err());
    // An unreadable frame file is an error, not the end of the stream.
    std::fs::create_dir(streams.join("002.main.h264")).unwrap();
    assert!(try_options(&["stream", "--streams", dir]).is_err());
    std::fs::remove_dir_all(&streams).unwrap();
}

#[test]
fn stall_goes_quiet_then_streams_again() {
    let mut out = Vec::new();
    let input = client(&[hello(&[]), ack(1), ack(2), ClientMsg::Ping { t: 5 }, ack(3), ClientMsg::Bye]);
    run(&options(&["stall", "0"]), input, &mut out).unwrap();
    let messages = decoded(&sent(out));
    let ids: Vec<u64> = messages
        .iter()
        .filter_map(|m| match m {
            ServerMsg::VideoFrame { frame_id, .. } => Some(*frame_id),
            _ => None,
        })
        .collect();
    assert_eq!(ids, [1, 2, 3]);
    assert!(messages.iter().any(|m| matches!(m, ServerMsg::Pong { t: 5, .. })));
    assert_eq!(options(&["stall", "6000"]).scenario, Scenario::Stall(6000));
    assert!(try_options(&["stall"]).is_err());
}

fn key(keycode: u32, pressed: bool) -> ClientMsg {
    ClientMsg::Key { keycode, pressed }
}

fn keymap(text: &str) -> ClientMsg {
    ClientMsg::Keymap { keymap: text.into() }
}

/// The input scenario against a client that acks both frames, then sends `messages`.
pub(super) fn input(args: &[&str], messages: &[ClientMsg]) -> Result<(), String> {
    let script = [&[hello(&[]), ack(1), ack(2)], messages].concat();
    run(&options(args), client(&script), Vec::new())
}

#[test]
fn input_parses_its_flags() {
    let parsed = options(&["input", "--keymap-first", "--expect-keys", "2"]);
    assert_eq!(parsed.scenario, Scenario::Input);
    assert!(parsed.keymap_first);
    assert_eq!(parsed.expect_keys, 2);
    assert!(try_options(&["stream", "--expect-keys", "2"]).is_err());
    assert!(try_options(&["handshake", "--keymap-first"]).is_err());
    assert!(try_options(&["stream", "--expect-keys", "0"]).is_err());
    assert!(try_options(&["input", "--expect-bye"]).is_err());
    assert!(try_options(&["input", "--frames", "3"]).is_err());
}

#[test]
fn input_checks_acks_at_the_clients_eof() {
    let script = [hello(&[]), key(30, true), key(30, false)];
    let error = run(&options(&["input"]), client(&script), Vec::new()).unwrap_err();
    assert!(error.contains("ack"), "{error}");
}

#[test]
fn input_accepts_balanced_keys() {
    let messages = [keymap("k"), key(30, true), key(30, false), ClientMsg::Bye];
    input(&["input", "--keymap-first", "--expect-keys", "2"], &messages).unwrap();
}

#[test]
fn input_ends_at_the_clients_eof_too() {
    input(&["input"], &[key(30, true), key(30, false)]).unwrap();
}

#[test]
fn input_refuses_a_held_key() {
    let error = input(&["input"], &[key(30, true), ClientMsg::Bye]).unwrap_err();
    assert!(error.contains("still held"), "{error}");
}

#[test]
fn input_refuses_a_key_pressed_twice() {
    let error = input(&["input"], &[key(30, true), key(30, true)]).unwrap_err();
    assert!(error.contains("pressed twice"), "{error}");
}

#[test]
fn input_refuses_release_without_press() {
    let error = input(&["input"], &[key(30, false), ClientMsg::Bye]).unwrap_err();
    assert!(error.contains("released but not held"), "{error}");
}

#[test]
fn input_refuses_key_before_keymap() {
    let error = input(&["input", "--keymap-first"], &[key(30, true), key(30, false)]).unwrap_err();
    assert!(error.contains("before the keymap"), "{error}");
}

#[test]
fn input_refuses_an_empty_keymap() {
    let error = input(&["input"], &[keymap("")]).unwrap_err();
    assert!(error.contains("empty keymap"), "{error}");
}

#[test]
fn input_counts_keys() {
    let messages = [key(30, true), key(30, false), ClientMsg::Bye];
    let error = input(&["input", "--expect-keys", "3"], &messages).unwrap_err();
    assert!(error.contains("at least 3"), "{error}");
}

#[test]
fn input_still_answers_pings() {
    let mut out = Vec::new();
    let script = [hello(&[]), ack(1), ack(2), ClientMsg::Ping { t: 7 }, ClientMsg::Bye];
    run(&options(&["input"]), client(&script), &mut out).unwrap();
    assert!(decoded(&sent(out)).iter().any(|m| matches!(m, ServerMsg::Pong { t: 7, .. })));
}

#[test]
fn cursor_sends_three_shapes_after_the_stream_config() {
    assert_eq!(options(&["cursor"]).scenario, Scenario::Cursor);
    let input = client(&[hello(&[]), ack(1), ack(2)]);
    let mut out = Vec::new();
    run(&options(&["cursor"]), input, &mut out).unwrap();
    let frames = sent(out);
    let messages = decoded(&frames);
    let config = messages.iter().position(|m| matches!(m, ServerMsg::StreamConfig { .. })).unwrap();
    let shapes: Vec<_> = frames
        .iter()
        .enumerate()
        .filter_map(|(index, frame)| match minicbor::decode(&frame.body) {
            Ok(ServerMsg::CursorShape { id, width, height, hot_x, hot_y, argb_len }) => {
                Some((index, (id, width, height, hot_x, hot_y, argb_len), frame.payload.clone()))
            }
            _ => None,
        })
        .collect();
    assert_eq!(shapes.len(), 3);
    assert!(shapes.iter().all(|(index, _, _)| *index > config));
    let (red, white) = ([0u8, 0, 255, 255], [255u8, 255, 255, 255]);
    assert_eq!(shapes[0].1, (7, 2, 2, 1, 1, 16));
    // The frame carries four bytes more than the shape declares: a client skips them.
    assert_eq!(shapes[0].2, [red, white, red, white, [0; 4]].concat());
    assert_eq!(shapes[1].1, (8, 2, 2, 5, 5, 16));
    assert_eq!(shapes[1].2.len(), 16);
    assert_eq!(shapes[2].1, (9, 2, 2, 0, 0, 15));
    assert_eq!(shapes[2].2.len(), 15);
    let video = messages.iter().filter(|m| matches!(m, ServerMsg::VideoFrame { .. })).count();
    assert_eq!(video, 2);
}

#[test]
fn cursor_valid_only_sends_one_shape() {
    assert!(options(&["cursor", "--valid-only"]).valid_only);
    assert!(try_options(&["stream", "--valid-only"]).is_err());
    let mut out = Vec::new();
    run(&options(&["cursor", "--valid-only"]), client(&[hello(&[]), ack(1), ack(2)]), &mut out).unwrap();
    let shapes = decoded(&sent(out)).into_iter().filter(|m| matches!(m, ServerMsg::CursorShape { .. })).count();
    assert_eq!(shapes, 1);
}

fn button(button: u32, pressed: bool) -> ClientMsg {
    ClientMsg::PointerButton { button, pressed }
}

fn motion(x: f64, y: f64) -> ClientMsg {
    ClientMsg::PointerMotion { x, y }
}

#[test]
fn input_accepts_balanced_pointer_input() {
    let axis = ClientMsg::PointerAxis { axis: gliff_proto::Axis::Vertical, value: 15.0, discrete: Some(1), stop: false };
    let messages = [motion(0.0, 720.0), button(0x110, true), axis, button(0x110, false), ClientMsg::Bye];
    input(&["input", "--expect-pointer", "4"], &messages).unwrap();
}

#[test]
fn input_refuses_a_button_pressed_twice() {
    let error = input(&["input"], &[button(0x110, true), button(0x110, true)]).unwrap_err();
    assert!(error.contains("button 272 pressed twice"), "{error}");
}

#[test]
fn input_refuses_a_button_released_unheld() {
    let error = input(&["input"], &[button(0x111, false)]).unwrap_err();
    assert!(error.contains("button 273 released but not held"), "{error}");
}

#[test]
fn input_refuses_a_button_held_at_eof() {
    let error = input(&["input"], &[button(0x110, true)]).unwrap_err();
    assert!(error.contains("buttons still held"), "{error}");
}

#[test]
fn input_refuses_motion_off_the_output() {
    for (x, y) in [(1281.0, 0.0), (-0.5, 0.0), (0.0, -0.5), (0.0, 720.5), (f64::NAN, 1.0), (f64::INFINITY, 0.0)] {
        let error = input(&["input"], &[motion(x, y)]).unwrap_err();
        assert!(error.contains("outside the 1280×720 output"), "{error}");
    }
}

fn scroll(value: f64, stop: bool) -> ClientMsg {
    ClientMsg::PointerAxis { axis: gliff_proto::Axis::Horizontal, value, discrete: None, stop }
}

#[test]
fn input_accepts_a_scroll_and_its_stop() {
    input(&["input"], &[scroll(-3.5, false), scroll(0.0, true), ClientMsg::Bye]).unwrap();
}

#[test]
fn input_refuses_a_stop_for_an_axis_that_never_scrolled() {
    let error = input(&["input"], &[scroll(0.0, true)]).unwrap_err();
    assert!(error.contains("stop for Horizontal, which isn't scrolling"), "{error}");
}

#[test]
fn input_refuses_a_scroll_value_that_isnt_finite() {
    let error = input(&["input"], &[scroll(f64::NAN, false)]).unwrap_err();
    assert!(error.contains("scroll by NaN"), "{error}");
}

#[test]
fn input_counts_pointer_messages() {
    assert_eq!(options(&["input", "--expect-pointer", "3"]).expect_pointer, 3);
    assert!(try_options(&["stream", "--expect-pointer", "3"]).is_err());
    let error = input(&["input", "--expect-pointer", "3"], &[motion(1.0, 1.0), motion(2.0, 2.0)]).unwrap_err();
    assert!(error.contains("at least 3 pointer messages, got 2"), "{error}");
}

fn resize(width: u32, height: u32, scale: f32) -> ClientMsg {
    ClientMsg::Resize { width, height, scale }
}

/// Each StreamConfig the server sent, as (width, height, view width, view height, scale_milli).
fn configs(out: Vec<u8>) -> Vec<(u32, u32, u32, u32, u32)> {
    decoded(&sent(out))
        .into_iter()
        .filter_map(|m| match m {
            ServerMsg::StreamConfig { width, height, view_width, view_height, scale_milli, .. } => {
                Some((width, height, view_width, view_height, scale_milli))
            }
            _ => None,
        })
        .collect()
}

#[test]
fn resize_parses_its_flags() {
    let parsed = options(&["resize", "--headless", "--expect-resizes", "2"]);
    assert_eq!(parsed.scenario, Scenario::Resize);
    assert!(parsed.headless);
    assert_eq!(parsed.expect_resizes, 2);
    assert!(try_options(&["stream", "--headless"]).is_err());
    assert!(try_options(&["stream", "--expect-resizes", "1"]).is_err());
    // Like input, resize always streams two frames and ends at Bye or EOF.
    assert!(try_options(&["resize", "--frames", "3"]).is_err());
    assert!(try_options(&["resize", "--expect-bye"]).is_err());
}

#[test]
fn resize_fits_a_mirror_never_larger() {
    let messages = [hello(&[]), ack(1), ack(2), resize(1000, 600, 2.0), ack(3), resize(4000, 3000, 2.0), ack(4), ClientMsg::Bye];
    let mut out = Vec::new();
    run(&options(&["resize", "--expect-resizes", "2"]), client(&messages), &mut out).unwrap();
    assert_eq!(configs(out), [(1280, 720, 1280, 720, 1000), (1000, 562, 1000, 562, 1000), (1280, 720, 1280, 720, 1000)]);
}

#[test]
fn resize_sends_nothing_for_a_mirror_already_that_size() {
    let mut out = Vec::new();
    run(&options(&["resize"]), client(&[hello(&[]), ack(1), ack(2), resize(1920, 1080, 2.0), ClientMsg::Bye]), &mut out).unwrap();
    assert_eq!(configs(out).len(), 1);
}

#[test]
fn resize_rounds_a_virtual_screen_as_hyprland_does() {
    let messages = [hello(&[]), ack(1), ack(2), resize(1366, 768, 1.25), ack(3), ClientMsg::Bye];
    let mut out = Vec::new();
    run(&options(&["resize", "--headless"]), client(&messages), &mut out).unwrap();
    let all = decoded(&sent(out.clone()));
    assert!(matches!(&all[0], ServerMsg::HelloAck { session, .. } if session.headless));
    assert_eq!(configs(out), [(1280, 720, 1280, 720, 1000), (1360, 760, 1360, 760, 1250)]);
}

#[test]
fn resize_refuses_the_same_request_twice() {
    let messages = [hello(&[]), ack(1), ack(2), resize(1000, 600, 2.0), ack(3), resize(1000, 600, 2.0), ClientMsg::Bye];
    let error = run(&options(&["resize"]), client(&messages), Vec::new()).unwrap_err();
    assert!(error.contains("twice"), "{error}");
}

#[test]
fn resize_refuses_a_size_the_server_ignores() {
    let messages = [hello(&[]), ack(1), ack(2), resize(319, 600, 2.0), ClientMsg::Bye];
    let error = run(&options(&["resize"]), client(&messages), Vec::new()).unwrap_err();
    assert!(error.contains("319"), "{error}");
}

#[test]
fn resize_refuses_a_scale_out_of_range() {
    for scale in [f32::NAN, 0.25, 5.0] {
        let messages = [hello(&[]), ack(1), ack(2), resize(1000, 600, scale), ClientMsg::Bye];
        let error = run(&options(&["resize"]), client(&messages), Vec::new()).unwrap_err();
        assert!(error.contains("scale"), "{error}");
    }
}

#[test]
fn resize_counts_resizes() {
    let error = run(&options(&["resize", "--expect-resizes", "1"]), client(&[hello(&[]), ack(1), ack(2), ClientMsg::Bye]), Vec::new()).unwrap_err();
    assert!(error.contains("expected at least 1 Resize"), "{error}");
}

#[test]
fn clean_mode_matches_upstream() {
    // hypr-ipc's own cases (`clean_mode_divides_into_whole_logical_pixels`).
    assert_eq!(resize::clean_mode(1290, 1926, 3.0), (1290, 1926));
    assert_eq!(resize::clean_mode(2560, 1440, 2.0), (2560, 1440));
    assert_eq!(resize::clean_mode(1920, 1080, 1.0), (1920, 1080));
    assert_eq!(resize::clean_mode(1366, 768, 1.25), (1360, 760));
    assert_eq!(resize::clean_mode(1290, 1925, 3.0), (1290, 1920));
    assert_eq!(resize::clean_mode(1001, 701, 1.5), (996, 696));
    assert_eq!(resize::clean_mode(1083, 2341, 2.5), (1080, 2340));
    assert_eq!(resize::clean_mode(1366, 768, 1.4), (1358, 756));
    assert_eq!(resize::clean_mode(1366, 768, 1.8), (1350, 756));
}

#[test]
fn nudge_accepted() {
    let messages = [keymap("k"), motion(99.0, 50.0), motion(100.0, 50.0), key(30, true), key(30, false), ClientMsg::Bye];
    input(&["input", "--expect-nudge", "--expect-keys", "2"], &messages).unwrap();
    assert!(options(&["input", "--expect-nudge"]).expect_nudge);
    assert!(try_options(&["stream", "--expect-nudge"]).is_err());
}

#[test]
fn a_single_motion_fails() {
    let error = input(&["input", "--expect-nudge"], &[motion(100.0, 50.0), ClientMsg::Bye]).unwrap_err();
    assert!(error.contains("expected a two-motion nudge first"), "{error}");
    let apart = [motion(10.0, 50.0), motion(100.0, 50.0), ClientMsg::Bye];
    let error = input(&["input", "--expect-nudge"], &apart).unwrap_err();
    assert!(error.contains("expected a two-motion nudge first"), "{error}");
}

#[test]
fn a_key_before_the_nudge_fails() {
    let messages = [key(30, true), key(30, false), motion(99.0, 50.0), motion(100.0, 50.0)];
    let error = input(&["input", "--expect-nudge"], &messages).unwrap_err();
    assert!(error.contains("expected a two-motion nudge first"), "{error}");
}

#[test]
fn a_nudge_off_the_left_edge_is_accepted() {
    // The client adds 1 to 0.001: the difference back isn't exactly 1 in f64.
    let messages = [motion(0.001 + 1.0, 7.0), motion(0.001, 7.0), ClientMsg::Bye];
    input(&["input", "--expect-nudge"], &messages).unwrap();
}
