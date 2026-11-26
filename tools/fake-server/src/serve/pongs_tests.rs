//! `--pong-delay` and `--coalesce-pongs`: when the input scenario answers a Ping.

use super::tests::{ack, decoded, hello, input, options, sent, try_options};
use super::*;
use crate::wire::Frame;

#[test]
fn pong_delay_holds_each_pong_back() {
    assert_eq!(options(&["input", "--pong-delay", "40"]).pong_delay, 40);
    assert!(try_options(&["stream", "--pong-delay", "40"]).is_err());
    assert!(try_options(&["input", "--pong-delay", "x"]).is_err());
    let start = std::time::Instant::now();
    input(&["input", "--pong-delay", "40"], &[ClientMsg::Ping { t: 1 }, ClientMsg::Bye]).unwrap();
    assert!(start.elapsed() >= std::time::Duration::from_millis(40));
}

/// Each script, as the client would send it, one frame at a time from its own thread; each
/// pause (milliseconds) comes before its script.
fn fed(steps: Vec<(u64, Vec<ClientMsg>)>) -> Feed {
    let (frames, feed) = std::sync::mpsc::channel();
    std::thread::spawn(move || {
        for (pause, messages) in steps {
            std::thread::sleep(std::time::Duration::from_millis(pause));
            for message in messages {
                let _ = frames.send(Ok(Some(Frame { body: body(&message), payload: Vec::new() })));
            }
        }
        let _ = frames.send(Ok(None));
    });
    feed
}

#[test]
fn coalesce_pongs_parses() {
    assert_eq!(options(&["input", "--coalesce-pongs", "40"]).coalesce_pongs, 40);
    assert!(try_options(&["stream", "--coalesce-pongs", "40"]).is_err());
    assert!(try_options(&["input", "--coalesce-pongs", "x"]).is_err());
    // The queue sets when a Pong goes: a delay as well would be ignored.
    assert!(try_options(&["input", "--coalesce-pongs", "40", "--pong-delay", "300"]).is_err());
}

/// As upstream's writer: a Pong waits behind the frame being written, and a newer one queued
/// meanwhile replaces it; Pings after it has gone are answered again.
#[test]
fn coalesce_pongs_drops_a_pong_a_newer_one_replaces() {
    let mut out = Vec::new();
    let feed = fed(vec![
        (0, vec![hello(&[]), ack(1), ack(2), ClientMsg::Ping { t: 1 }, ClientMsg::Ping { t: 2 }]),
        (150, vec![ClientMsg::Ping { t: 3 }]),
        (150, vec![ClientMsg::Bye]),
    ]);
    let start = std::time::Instant::now();
    run_fed(&options(&["input", "--coalesce-pongs", "40"]), feed, &mut out).unwrap();
    let pongs: Vec<u64> = decoded(&sent(out))
        .iter()
        .filter_map(|m| if let ServerMsg::Pong { t, .. } = m { Some(*t) } else { None })
        .collect();
    assert_eq!(pongs, [2, 3]);
    assert!(start.elapsed() >= std::time::Duration::from_millis(300));
}
