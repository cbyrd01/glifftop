//! The clipboard scenarios. Files aren't shared: a client offer listing files fails
//! either one.
//!
//! `clipboard-offer [--hostile]` offers text, HTML and a PNG and serves each request: an odd id
//! not in use, the offer's serial, a type and never a file. The client sends no `Data` and
//! aborts only what it asked for. With `--hostile` a stray chunk comes first and each HTML is
//! one chunk over the limit, which the client must abort, keeping the session. That is
//! Glifftop's rule (one bad transfer ends alone); upstream's own client drops the connection.
//!
//! `clipboard-request` reads the client's offer (text, no files), then the text at once, in order
//! and on the pattern (no input needed first). With four chunks unacked it asks for
//! a type not offered, which must be refused before any fifth chunk: a client past the window is
//! caught without timing. Then refusals for a stale serial and an odd id, and an offer of its
//! own says it's done.

use super::Session;
use gliff_proto::clipboard::{Assembler, CHUNK, MAX_ITEM, TEXT_MIME, TEXT_MIMES, WINDOW};
use gliff_proto::{ClientMsg, ClipboardFile, ClipboardItem, ServerMsg};
use std::collections::{BTreeMap, BTreeSet};
use std::io::{Read, Write};

const HTML: &str = "text/html";
const PNG: &str = "image/png";
/// The serial of the server's offer, in either scenario.
const SERIAL: u32 = 1;
/// `--hostile`'s chunk for a transfer the client never started.
const STRAY: u32 = 99;

/// The test pattern: byte i of a payload, from `offset`, is i % 251.
pub(super) fn pattern(offset: u64, len: usize) -> Vec<u8> {
    (0..len as u64).map(|i| ((offset + i) % 251) as u8).collect()
}

fn no_files(files: &[ClipboardFile]) -> Result<(), String> {
    if files.is_empty() { Ok(()) } else { Err("the client offered files".into()) }
}

impl<R: Read, W: Write> Session<'_, R, W> {
    pub(super) fn clipboard_offer(&mut self) -> Result<(), String> {
        let hostile = self.options.hostile;
        if hostile {
            let stray = ServerMsg::ClipboardData { id: STRAY, offset: 0, data_len: 3, done: true };
            self.send(&stray, &[&[1, 2, 3]])?;
        }
        let mut mime_types: Vec<String> = TEXT_MIMES.iter().map(|m| m.to_string()).collect();
        mime_types.extend([HTML.to_string(), PNG.to_string()]);
        self.send(&ServerMsg::ClipboardOffer { serial: SERIAL, mime_types, files: Vec::new() }, &[])?;
        // Each item is one final chunk: the client acks none of them.
        let mut sent = BTreeMap::new();
        let mut aborted = BTreeSet::new();
        let mut html = BTreeSet::new();
        loop {
            let Some(message) = self.recv()? else {
                self.acks.finish().map_err(|e| format!("the client closed before acking: {e}"))?;
                break;
            };
            match message {
                ClientMsg::ClipboardRequest { id, serial, item } => {
                    if id.is_multiple_of(2) {
                        return Err(format!("request id {id} is even: a client's are odd"));
                    }
                    if sent.contains_key(&id) {
                        return Err(format!("request id {id} reused"));
                    }
                    if serial != SERIAL {
                        return Err(format!("request for serial {serial}, offered {SERIAL}"));
                    }
                    let ClipboardItem::Mime(mime) = item else {
                        return Err(format!("request {id} for a file: the offer has none"));
                    };
                    let bytes = match mime.as_str() {
                        HTML if hostile => {
                            html.insert(id);
                            pattern(0, CHUNK + 1)
                        }
                        HTML => b"<b>hi</b>".to_vec(),
                        PNG => pattern(0, 100),
                        text if TEXT_MIMES.contains(&text) => "héllo".as_bytes().to_vec(),
                        _ => Vec::new(),
                    };
                    sent.insert(id, bytes.len() as u64);
                    if bytes.is_empty() {
                        self.send(&ServerMsg::ClipboardAbort { id }, &[])?;
                        continue;
                    }
                    let data = ServerMsg::ClipboardData { id, offset: 0, data_len: bytes.len() as u32, done: true };
                    self.send(&data, &[&bytes])?;
                }
                ClientMsg::ClipboardAck { id, received } => {
                    if sent.get(&id).is_none_or(|&len| received > len) {
                        return Err(format!("ack of {received} bytes for {id}, more than was sent"));
                    }
                }
                ClientMsg::ClipboardAbort { id } => {
                    if !sent.contains_key(&id) && !(hostile && id == STRAY) {
                        return Err(format!("abort of {id}, which the client never requested"));
                    }
                    aborted.insert(id);
                }
                ClientMsg::ClipboardData { id, .. } => {
                    return Err(format!("data for {id} from the client: the server asked for nothing"));
                }
                ClientMsg::ClipboardOffer { files, .. } => no_files(&files)?,
                other => {
                    if self.handle(other)? {
                        break;
                    }
                }
            }
        }
        if let Some(id) = html.difference(&aborted).next() {
            return Err(format!("the client didn't abort {id}, an oversized HTML"));
        }
        if hostile && html.is_empty() {
            return Err("the client never asked for the HTML".into());
        }
        Ok(())
    }

    pub(super) fn clipboard_request(&mut self) -> Result<(), String> {
        let serial = match self.next_clipboard("an offer")? {
            (ClientMsg::ClipboardOffer { serial, mime_types, files }, _) => {
                no_files(&files)?;
                let has = |wanted: &str| mime_types.iter().any(|m| m == wanted);
                if !has(TEXT_MIME) {
                    return Err(format!("offer {mime_types:?} lacks {TEXT_MIME}"));
                }
                serial
            }
            (other, _) => return Err(format!("expected an offer, got {other:?}")),
        };
        let text = || ClipboardItem::Mime(TEXT_MIME.into());
        self.request(2, serial, text())?;
        self.receive_pattern(2, serial)?;
        self.request(6, serial.wrapping_sub(1), text())?;
        self.expect_abort(6)?;
        self.request(7, serial, text())?;
        self.expect_abort(7)?;
        // The host's own copy: tells the client the checks are over.
        let offer = ServerMsg::ClipboardOffer { serial: SERIAL, mime_types: vec![TEXT_MIME.into()], files: Vec::new() };
        self.send(&offer, &[])?;
        loop {
            match self.recv()? {
                Some(message) => {
                    if self.handle(message)? {
                        return Ok(());
                    }
                }
                None => return self.acks.finish().map_err(|e| format!("the client closed before acking: {e}")),
            }
        }
    }

    fn request(&mut self, id: u32, serial: u32, item: ClipboardItem) -> Result<(), String> {
        self.send(&ServerMsg::ClipboardRequest { id, serial, item }, &[])
    }

    /// The client's next clipboard message and its payload; frame acks and pings are handled
    /// on the way, input and the rest ignored. Bye or EOF fails.
    fn next_clipboard(&mut self, waiting_for: &str) -> Result<(ClientMsg, Vec<u8>), String> {
        loop {
            let Some((message, payload)) = self.recv_with_payload()? else {
                return Err(format!("the client closed before {waiting_for}"));
            };
            match message {
                ClientMsg::ClipboardOffer { .. }
                | ClientMsg::ClipboardRequest { .. }
                | ClientMsg::ClipboardData { .. }
                | ClientMsg::ClipboardAck { .. }
                | ClientMsg::ClipboardAbort { .. } => return Ok((message, payload)),
                other => {
                    if self.handle(other)? {
                        return Err(format!("Bye before {waiting_for}"));
                    }
                }
            }
        }
    }

    fn expect_abort(&mut self, id: u32) -> Result<(), String> {
        match self.next_clipboard("a refusal")? {
            (ClientMsg::ClipboardAbort { id: got }, _) if got == id => Ok(()),
            (other, _) => Err(format!("expected Abort for {id}, got {other:?}")),
        }
    }

    /// Reads transfer `id` to its end: in order and on the pattern, over more than four chunks.
    /// With four unacked, a type not offered is asked for (id 4) and must be refused before a
    /// fifth chunk: a client that waits for the ack can't have sent one. Then the window's ack.
    fn receive_pattern(&mut self, id: u32, serial: u32) -> Result<(), String> {
        let mut assembler = Assembler::new(Some(MAX_ITEM));
        let mut unacked = 0;
        let mut probed = false;
        loop {
            let (ClientMsg::ClipboardData { id: got, offset, data_len, done }, payload) =
                self.next_clipboard("the text")?
            else {
                return Err(format!("expected the text's chunks for {id}"));
            };
            if got != id {
                return Err(format!("a chunk for {got} while reading {id}"));
            }
            assembler.accept(offset, data_len, done).map_err(|e| format!("transfer {id}: {e}"))?;
            if payload.len() != data_len as usize || payload != pattern(offset, payload.len()) {
                return Err(format!("transfer {id}: bytes off the pattern at {offset}"));
            }
            if done {
                return if probed { Ok(()) } else { Err("the text must span more than four chunks".into()) };
            }
            unacked += 1;
            if unacked == WINDOW {
                if !probed {
                    self.request(4, serial, ClipboardItem::Mime(PNG.into()))?;
                    match self.next_clipboard("the probe's refusal")? {
                        (ClientMsg::ClipboardData { id: got, .. }, _) if got == id => {
                            return Err(format!("transfer {id}: a chunk past the window of {WINDOW}"));
                        }
                        (ClientMsg::ClipboardAbort { id: 4 }, _) => {}
                        (other, _) => return Err(format!("expected Abort for 4, got {other:?}")),
                    }
                    probed = true;
                }
                self.send(&ServerMsg::ClipboardAck { id, received: assembler.received }, &[])?;
                unacked = 0;
            }
        }
    }
}
