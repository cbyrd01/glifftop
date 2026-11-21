//! The `cursor` scenario's shapes: one a client shows, and two it must ignore (upstream's
//! `remote_cursor` refuses a hotspot outside the image; a shape whose pixels don't fill it
//! is skipped by `read_cursor`) while the stream goes on.

use super::Session;
use gliff_proto::ServerMsg;
use std::io::{Read, Write};

impl<R: Read, W: Write> Session<'_, R, W> {
    pub(super) fn cursor_shapes(&mut self) -> Result<(), String> {
        let (red, white) = ([0u8, 0, 255, 255], [255u8, 255, 255, 255]);
        let pixels = [red, white, red, white].concat();
        let shape = |id, hot, argb_len| ServerMsg::CursorShape {
            id,
            width: 2,
            height: 2,
            hot_x: hot,
            hot_y: hot,
            argb_len,
        };
        // Bytes past what a message declares are skipped (upstream `read_msg`).
        self.send(&shape(7, 1, 16), &[&pixels, &[0; 4]])?;
        if self.options.valid_only {
            return Ok(());
        }
        self.send(&shape(8, 5, 16), &[&pixels])?;
        self.send(&shape(9, 0, 15), &[&pixels[..15]])
    }
}
