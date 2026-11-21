//! The `resize` scenario: answers each Resize much as upstream's server does (`session.rs`
//! `resize`) and checks the client never loops. A virtual screen (`--headless`) takes the
//! requested mode rounded by Hyprland's `clean_mode`; a mirror streams its 1280×720 output
//! fitted into the window, never larger (`fit_mirror`). Each new size or scale is a new
//! StreamConfig and a keyframe. Unlike upstream, it neither clamps to the Hello caps nor
//! applies `headless_cap`, and it fails a scale that upstream would clamp: the client is
//! expected never to send one.

use super::Session;
use gliff_proto::ClientMsg;
use std::io::{Read, Write};

/// The mirrored output's size, as in the HelloAck.
const OUTPUT: (u32, u32) = (1280, 720);

impl<R: Read, W: Write> Session<'_, R, W> {
    /// Handles the client's messages until Bye or EOF, answering each Resize.
    pub(super) fn resize(&mut self) -> Result<(), String> {
        let mut last = None;
        let mut resizes = 0u64;
        // The current mode: (width, height, scale_milli).
        let mut mode = (OUTPUT.0, OUTPUT.1, 1000u32);
        loop {
            let Some(message) = self.recv()? else {
                self.acks.finish().map_err(|e| format!("the client closed before acking: {e}"))?;
                break;
            };
            let ClientMsg::Resize { width, height, scale } = message else {
                if self.handle(message)? {
                    break;
                }
                continue;
            };
            resizes += 1;
            // Upstream ignores these; a client that sends them would keep sending them.
            if width < 320 || height < 240 {
                return Err(format!("Resize to {width}×{height}, which the server ignores"));
            }
            if !(scale.is_finite() && (0.5..=4.0).contains(&scale)) {
                return Err(format!("Resize with scale {scale}"));
            }
            if last == Some((width, height, scale.to_bits())) {
                return Err(format!("the same Resize ({width}×{height} at {scale}) twice"));
            }
            last = Some((width, height, scale.to_bits()));
            let next = if self.options.headless {
                let (w, h) = clean_mode(width & !1, height & !1, scale);
                (w, h, (scale * 1000.0).round() as u32)
            } else {
                let (ow, oh) = (f64::from(OUTPUT.0), f64::from(OUTPUT.1));
                let fit = (f64::from(width) / ow).min(f64::from(height) / oh).min(1.0);
                let side = |v: f64| ((v * fit).round() as u32).max(2) & !1;
                (side(ow), side(oh), 1000)
            };
            if next != mode {
                mode = next;
                self.config(mode.0, mode.1, mode.2, 60)?;
                self.frames(1, true)?;
            }
        }
        if resizes < self.options.expect_resizes {
            return Err(format!("expected at least {} Resize, got {resizes}", self.options.expect_resizes));
        }
        Ok(())
    }
}

/// Hyprland's rounding of a mode so the scale divides it into whole logical pixels, kept
/// even: a port of hypr-ipc's `clean_mode` at the pinned gliff rev (not a dependency: the
/// crate brings its own).
pub(super) fn clean_mode(width: u32, height: u32, scale: f32) -> (u32, u32) {
    let s = f64::from(scale);
    let Some(q) = (1..=8u32).find(|q| {
        let numerator = s * f64::from(*q);
        (numerator - numerator.round()).abs() < 1e-4
    }) else {
        return (width, height);
    };
    let p = (s * f64::from(q)).round() as u32;
    let step = if p.is_multiple_of(2) { p } else { 2 * p };
    let fit = |v: u32| (v - v % step).max(step);
    (fit(width), fit(height))
}
