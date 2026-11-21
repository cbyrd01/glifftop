//! The clipboard scenarios, run against scripted clients over in-memory streams.

use super::clipboard::pattern;
use super::tests::{ack, hello, try_options as options};
use super::*;
use crate::wire::Frame;
use gliff_proto::clipboard::{CHUNK, TEXT_MIME};
use gliff_proto::ClipboardItem;
use std::io::Cursor;

/// A client sending `messages`, each with its payload, after its Hello and the acks of the two
/// frames every clipboard scenario streams first.
fn client(messages: Vec<(ClientMsg, Vec<u8>)>) -> Cursor<Vec<u8>> {
    let mut bytes = Vec::new();
    for (message, payload) in [msg(hello(&[])), msg(ack(1)), msg(ack(2))].into_iter().chain(messages) {
        write_frame(&mut bytes, &body(&message), &[&payload]).unwrap();
    }
    Cursor::new(bytes)
}

fn msg(message: ClientMsg) -> (ClientMsg, Vec<u8>) {
    (message, Vec::new())
}

fn request(id: u32, serial: u32, mime: &str) -> (ClientMsg, Vec<u8>) {
    msg(ClientMsg::ClipboardRequest { id, serial, item: ClipboardItem::Mime(mime.into()) })
}

fn data(id: u32, offset: u64, payload: Vec<u8>, done: bool) -> (ClientMsg, Vec<u8>) {
    (ClientMsg::ClipboardData { id, offset, data_len: payload.len() as u32, done }, payload)
}

/// What the server wrote: each message with its payload.
fn sent(bytes: Vec<u8>) -> Vec<(ServerMsg, Vec<u8>)> {
    let mut input = Cursor::new(bytes);
    std::iter::from_fn(|| read_frame(&mut input).unwrap())
        .filter_map(|Frame { body, payload }| Some((minicbor::decode(&body).ok()?, payload)))
        .collect()
}

fn run_with(args: &[&str], messages: Vec<(ClientMsg, Vec<u8>)>) -> Result<Vec<(ServerMsg, Vec<u8>)>, String> {
    let mut out = Vec::new();
    run(&options(args)?, client(messages), &mut out)?;
    Ok(sent(out))
}

fn served(sent: &[(ServerMsg, Vec<u8>)], id: u32) -> Option<&[u8]> {
    sent.iter().find_map(|(message, payload)| match message {
        ServerMsg::ClipboardData { id: got, done: true, .. } if *got == id => Some(&payload[..]),
        _ => None,
    })
}

#[test]
fn clipboard_flags() {
    assert!(options(&["clipboard-offer", "--hostile"]).unwrap().hostile);
    assert!(options(&["clipboard-request", "--hostile"]).is_err());
    assert!(options(&["stream", "--hostile"]).is_err());
    assert!(options(&["clipboard-request", "--frames", "3"]).is_err());
}

#[test]
fn clipboard_offer_serves_each_type() {
    let sent = run_with(
        &["clipboard-offer"],
        vec![request(1, 1, "UTF8_STRING"), request(3, 1, "text/html"), request(5, 1, "image/png"), msg(ClientMsg::Bye)],
    )
    .unwrap();
    let offer = sent.iter().find_map(|(m, _)| match m {
        ServerMsg::ClipboardOffer { serial: 1, mime_types, files } => Some((mime_types.clone(), files.len())),
        _ => None,
    });
    let (mimes, files) = offer.expect("an offer");
    assert_eq!(files, 0);
    assert!(mimes.iter().any(|m| m == TEXT_MIME) && mimes.iter().any(|m| m == "image/png"));
    assert_eq!(served(&sent, 1), Some("héllo".as_bytes()));
    assert_eq!(served(&sent, 3), Some(&b"<b>hi</b>"[..]));
    assert_eq!(served(&sent, 5), Some(&pattern(0, 100)[..]));
}

#[test]
fn clipboard_offer_refuses_an_even_id_a_stale_serial_and_a_file() {
    let bye = || msg(ClientMsg::Bye);
    assert!(run_with(&["clipboard-offer"], vec![request(2, 1, TEXT_MIME), bye()]).unwrap_err().contains("even"));
    assert!(run_with(&["clipboard-offer"], vec![request(1, 2, TEXT_MIME), bye()]).unwrap_err().contains("serial"));
    let file = msg(ClientMsg::ClipboardRequest { id: 1, serial: 1, item: ClipboardItem::File(0) });
    assert!(run_with(&["clipboard-offer"], vec![file, bye()]).unwrap_err().contains("file"));
}

#[test]
fn clipboard_offer_refuses_an_ack_past_what_was_sent() {
    let ack = msg(ClientMsg::ClipboardAck { id: 1, received: 7 });
    let error = run_with(&["clipboard-offer"], vec![request(1, 1, TEXT_MIME), ack, msg(ClientMsg::Bye)]);
    assert!(error.unwrap_err().contains("ack"));
}

#[test]
fn hostile_sends_a_stray_chunk_and_an_oversized_html_chunk() {
    let messages = || vec![request(1, 1, "text/html"), msg(ClientMsg::ClipboardAbort { id: 1 }), msg(ClientMsg::Bye)];
    let sent = run_with(&["clipboard-offer", "--hostile"], messages()).unwrap();
    let stray = sent.iter().position(|(m, _)| matches!(m, ServerMsg::ClipboardData { id: 99, .. }));
    let offer = sent.iter().position(|(m, _)| matches!(m, ServerMsg::ClipboardOffer { .. }));
    assert!(stray.unwrap() < offer.unwrap());
    assert_eq!(served(&sent, 1).map(<[u8]>::len), Some(CHUNK + 1));
    let unaborted = vec![request(1, 1, "text/html"), msg(ClientMsg::Bye)];
    assert!(run_with(&["clipboard-offer", "--hostile"], unaborted).unwrap_err().contains("abort"));
    let never_asked = vec![msg(ClientMsg::Bye)];
    assert!(run_with(&["clipboard-offer", "--hostile"], never_asked).unwrap_err().contains("never asked"));
}

#[test]
fn clipboard_offer_refuses_what_a_client_must_not_send() {
    let run = |messages: Vec<_>| run_with(&["clipboard-offer"], messages).unwrap_err();
    let bye = || msg(ClientMsg::Bye);
    let files = ClientMsg::ClipboardOffer {
        serial: 3,
        mime_types: vec![TEXT_MIME.into()],
        files: vec![gliff_proto::ClipboardFile { path: "a".into(), size: 1, dir: false }],
    };
    assert!(run(vec![msg(files), bye()]).contains("offered files"));
    assert!(run(vec![data(1, 0, vec![1], true), bye()]).contains("asked for nothing"));
    assert!(run(vec![msg(ClientMsg::ClipboardAbort { id: 5 }), bye()]).contains("never requested"));
    assert!(run(vec![request(1, 1, TEXT_MIME), request(1, 1, TEXT_MIME), bye()]).contains("reused"));
    // A client's own offer without files is fine.
    let plain = ClientMsg::ClipboardOffer { serial: 3, mime_types: vec![TEXT_MIME.into()], files: Vec::new() };
    assert!(run_with(&["clipboard-offer"], vec![msg(plain), bye()]).is_ok());
}

#[test]
fn hostile_needs_every_html_request_aborted() {
    let messages = vec![
        request(1, 1, "text/html"),
        request(3, 1, "text/html"),
        msg(ClientMsg::ClipboardAbort { id: 3 }),
        msg(ClientMsg::Bye),
    ];
    let error = run_with(&["clipboard-offer", "--hostile"], messages).unwrap_err();
    assert!(error.contains("abort 1"), "{error}");
}

/// The client's side of `clipboard-request` for a text of `len` pattern bytes, in chunks of
/// `chunk`: its offer, then the text at once, refusing the type not offered once four chunks
/// wait for their ack, then the two refusals.
fn a_good_client(serial: u32, len: usize, chunk: usize) -> Vec<(ClientMsg, Vec<u8>)> {
    let mut messages =
        vec![msg(ClientMsg::ClipboardOffer { serial, mime_types: vec![TEXT_MIME.into()], files: Vec::new() })];
    let mut offset = 0;
    let mut chunks = 0;
    while offset < len {
        let end = (offset + chunk).min(len);
        messages.push(data(2, offset as u64, pattern(offset as u64, end - offset), end == len));
        offset = end;
        chunks += 1;
        if chunks == 4 && offset < len {
            messages.push(msg(ClientMsg::ClipboardAbort { id: 4 }));
        }
    }
    messages.extend([
        msg(ClientMsg::ClipboardAbort { id: 6 }),
        msg(ClientMsg::ClipboardAbort { id: 7 }),
        msg(ClientMsg::Bye),
    ]);
    messages
}

/// `messages` with the first one `matching` replaced by `with`.
fn swapped(
    mut messages: Vec<(ClientMsg, Vec<u8>)>, matching: impl Fn(&ClientMsg) -> bool, with: (ClientMsg, Vec<u8>),
) -> Vec<(ClientMsg, Vec<u8>)> {
    let index = messages.iter().position(|(m, _)| matching(m)).expect("a message to replace");
    messages[index] = with;
    messages
}

const LONG: usize = 4 * CHUNK + 10;

#[test]
fn clipboard_request_reads_the_text_at_once() {
    let sent = run_with(&["clipboard-request"], a_good_client(7, LONG, CHUNK)).unwrap();
    let requests: Vec<_> = sent
        .iter()
        .filter_map(|(m, _)| match m {
            ServerMsg::ClipboardRequest { id, serial, item } => Some((*id, *serial, item.clone())),
            _ => None,
        })
        .collect();
    let text = ClipboardItem::Mime(TEXT_MIME.into());
    assert_eq!(
        requests,
        [(2, 7, text.clone()), (4, 7, ClipboardItem::Mime("image/png".into())), (6, 6, text.clone()), (7, 7, text)]
    );
    // Acked once the window is full and the probe refused, never before.
    let acks: Vec<_> = sent
        .iter()
        .filter_map(|(m, _)| match m {
            ServerMsg::ClipboardAck { id, received } => Some((*id, *received)),
            _ => None,
        })
        .collect();
    assert_eq!(acks, [(2, 4 * CHUNK as u64)]);
    // Then its own offer: the client sees the checks are over.
    assert!(matches!(&sent.last().unwrap().0, ServerMsg::ClipboardOffer { serial: 1, files, .. } if files.is_empty()));
}

#[test]
fn clipboard_request_refuses_a_bad_client() {
    let run = |messages| run_with(&["clipboard-request"], messages).unwrap_err();
    let good = || a_good_client(7, LONG, CHUNK);
    let is_offer = |m: &ClientMsg| matches!(m, ClientMsg::ClipboardOffer { .. });
    let no_text = ClientMsg::ClipboardOffer { serial: 7, mime_types: vec!["text/html".into()], files: Vec::new() };
    assert!(run(swapped(good(), is_offer, msg(no_text))).contains("lacks"));
    let files = ClientMsg::ClipboardOffer {
        serial: 7,
        mime_types: vec![TEXT_MIME.into()],
        files: vec![gliff_proto::ClipboardFile { path: "a".into(), size: 1, dir: false }],
    };
    assert!(run(swapped(good(), is_offer, msg(files))).contains("offered files"));
    let is = |id| move |m: &ClientMsg| matches!(m, ClientMsg::ClipboardData { id: got, .. } if *got == id);
    // An empty answer (the old early-read rule) isn't the text.
    assert!(run(swapped(good(), is(2), data(2, 0, Vec::new(), true))).contains("more than four chunks"));
    assert!(run(swapped(good(), is(2), data(2, 0, vec![9; 10], false))).contains("off the pattern"));
    assert!(run(a_good_client(7, CHUNK + 1, CHUNK + 1)).contains("exceeds"));
    assert!(run(a_good_client(7, 10, CHUNK)).contains("more than four chunks"));
    let is_abort = |id| move |m: &ClientMsg| matches!(m, ClientMsg::ClipboardAbort { id: got } if *got == id);
    assert!(run(swapped(good(), is_abort(4), data(4, 0, Vec::new(), true))).contains("expected Abort for 4"));
    assert!(run(swapped(good(), is_abort(6), data(6, 0, Vec::new(), true))).contains("expected Abort"));
}

/// A client that sends a fifth chunk before the server's ack is caught: the probe finds the
/// chunk ahead of its refusal.
#[test]
fn clipboard_request_refuses_a_client_past_the_window() {
    let mut messages = a_good_client(7, LONG, CHUNK);
    let probe = messages.iter().position(|(m, _)| matches!(m, ClientMsg::ClipboardAbort { id: 4 })).unwrap();
    messages.swap(probe, probe + 1);
    let error = run_with(&["clipboard-request"], messages).unwrap_err();
    assert!(error.contains("past the window"), "{error}");
}
