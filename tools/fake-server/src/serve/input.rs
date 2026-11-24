//! The `input` scenario's checks: every Key and pointer button press is released exactly once,
//! nothing is held at the end, motion stays on the streamed output, a scroll's value is finite
//! and its stop follows a scroll of that axis, an empty Keymap is refused, and (with its flags)
//! the Keymap comes first, a window activation's nudge comes before any other input, and enough
//! keys and pointer messages arrive.

use super::Session;
use gliff_proto::{Axis, ClientMsg};
use std::collections::BTreeSet;
use std::io::{Read, Write};

impl<R: Read, W: Write> Session<'_, R, W> {
    /// Handles the client's messages until Bye or EOF, still acking and ponging, then checks
    /// what is still held and the counts. Frames still in flight at Bye are fine: a client disconnecting never sees them.
    pub(super) fn input(&mut self) -> Result<(), String> {
        let mut held = BTreeSet::new();
        let mut buttons = BTreeSet::new();
        let mut keys = 0u64;
        let mut pointer = 0u64;
        // Vertical, horizontal: scrolled since its last stop.
        let mut scrolling = [false; 2];
        let (width, height) = (f64::from(self.size.0), f64::from(self.size.1));
        let mut keymap = false;
        // With --expect-nudge: the motions seen while the nudge is still due.
        let mut nudge: Option<Vec<(f64, f64)>> = self.options.expect_nudge.then(Vec::new);
        loop {
            let Some(message) = self.recv()? else {
                // Closed without Bye: every frame must have been acked, as in the other scenarios.
                self.acks.finish().map_err(|e| format!("the client closed before acking: {e}"))?;
                break;
            };
            if let Some(motions) = &mut nudge {
                match message {
                    ClientMsg::PointerMotion { x, y } => {
                        motions.push((x, y));
                        if motions.len() == 2 {
                            let ((x0, y0), (x1, y1)) = (motions[0], motions[1]);
                            // 1 apart, as the client computed it (x + 1 isn't exact in f64).
                            if ((x0 - x1).abs() - 1.0).abs() > 1e-9 || y0 != y1 {
                                return Err(NUDGE.into());
                            }
                            nudge = None;
                        }
                    }
                    ClientMsg::Key { .. } | ClientMsg::PointerButton { .. } | ClientMsg::PointerAxis { .. } => {
                        return Err(NUDGE.into());
                    }
                    _ => {}
                }
            }
            match message {
                ClientMsg::Keymap { keymap: text } if text.is_empty() => return Err("empty keymap".into()),
                ClientMsg::Keymap { .. } => keymap = true,
                ClientMsg::Key { keycode, pressed } => {
                    if self.options.keymap_first && !keymap {
                        return Err(format!("key {keycode} before the keymap"));
                    }
                    keys += 1;
                    track(&mut held, "key", keycode, pressed)?;
                }
                ClientMsg::PointerMotion { x, y } => {
                    pointer += 1;
                    if !(0.0..=width).contains(&x) || !(0.0..=height).contains(&y) {
                        return Err(format!("motion to ({x}, {y}), outside the {width}×{height} output"));
                    }
                }
                ClientMsg::PointerButton { button, pressed } => {
                    pointer += 1;
                    track(&mut buttons, "button", button, pressed)?;
                }
                ClientMsg::PointerAxis { axis, value, stop, .. } => {
                    pointer += 1;
                    if !value.is_finite() {
                        return Err(format!("scroll by {value} on {axis:?}"));
                    }
                    let scrolled = &mut scrolling[if axis == Axis::Vertical { 0 } else { 1 }];
                    if stop && !*scrolled {
                        return Err(format!("stop for {axis:?}, which isn't scrolling"));
                    }
                    *scrolled = !stop;
                }
                other => {
                    if self.handle(other)? {
                        break;
                    }
                }
            }
        }
        if nudge.is_some() {
            return Err(NUDGE.into());
        }
        if keys < self.options.expect_keys {
            return Err(format!("expected at least {} keys, got {keys}", self.options.expect_keys));
        }
        if pointer < self.options.expect_pointer {
            return Err(format!("expected at least {} pointer messages, got {pointer}", self.options.expect_pointer));
        }
        if !held.is_empty() {
            return Err(format!("keys still held at the end: {held:?}"));
        }
        if !buttons.is_empty() {
            return Err(format!("buttons still held at the end: {buttons:?}"));
        }
        Ok(())
    }
}

const NUDGE: &str = "expected a two-motion nudge first";

/// A press of something already held, or a release of something not held, fails.
fn track(held: &mut BTreeSet<u32>, what: &str, code: u32, pressed: bool) -> Result<(), String> {
    if pressed && !held.insert(code) {
        return Err(format!("{what} {code} pressed twice"));
    }
    if !pressed && !held.remove(&code) {
        return Err(format!("{what} {code} released but not held"));
    }
    Ok(())
}
