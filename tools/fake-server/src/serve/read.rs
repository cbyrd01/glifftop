//! Reading the client's messages: from `input`, or from the feed (`--coalesce-pongs`).

use super::Session;
use crate::wire::read_frame;
use gliff_proto::ClientMsg;
use std::io::{self, Read, Write};

impl<R: Read, W: Write> Session<'_, R, W> {
    /// The client's next message, or None at the end of its stream. As upstream's
    /// `read_msg`, a message whose variant v0.4.3 doesn't know is skipped with its payload.
    pub(super) fn recv(&mut self) -> Result<Option<ClientMsg>, String> {
        Ok(self.recv_with_payload()?.map(|(message, _)| message))
    }

    /// `recv`, keeping the message's payload (a clipboard chunk's bytes).
    pub(super) fn recv_with_payload(&mut self) -> Result<Option<(ClientMsg, Vec<u8>)>, String> {
        loop {
            let frame = match self.feed {
                Some(_) => self.next_fed_frame()?,
                None => read_frame(&mut self.input).map_err(|e| format!("read failed: {e}"))?,
            };
            let Some(frame) = frame else {
                return Ok(None);
            };
            match minicbor::decode(&frame.body) {
                Ok(message) => return Ok(Some((message, frame.payload))),
                Err(e) if is_unknown_message(&frame.body, &e) => continue,
                Err(e) => return Err(format!("undecodable client message: {e}")),
            }
        }
    }

    /// Reads and discards everything until the client closes.
    pub(super) fn drain(&mut self) -> Result<(), String> {
        io::copy(&mut self.input, &mut io::sink()).map(drop).map_err(|e| format!("read failed: {e}"))
    }
}

/// Whether `e` is the message's own variant being unknown, not a bad value inside a known
/// message (upstream gliff-transport `is_unknown_message`).
fn is_unknown_message(body: &[u8], e: &minicbor::decode::Error) -> bool {
    let mut d = minicbor::Decoder::new(body);
    e.is_unknown_variant() && d.array().is_ok() && e.position() == Some(d.position())
}
