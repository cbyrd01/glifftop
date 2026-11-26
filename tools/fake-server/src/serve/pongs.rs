//! `--coalesce-pongs MS`: Pongs as upstream's writer queues them. Upstream's session queues each
//! Pong for its writer task, and a newer Pong replaces one still queued (`writer.rs`,
//! `Queue::push`): while a video frame is being written, an earlier Ping goes unanswered. Here a
//! Pong waits MS from when the first of them was queued, as behind that frame, and the client's
//! frames are read meanwhile, from a thread of their own (`run_fed`).

use super::Session;
use crate::wire::Frame;
use gliff_proto::ServerMsg;
use std::io::{self, Read, Write};
use std::sync::mpsc::{Receiver, RecvTimeoutError};
use std::time::{Duration, Instant};

/// The client's frames, read on another thread: `Ok(None)` at the end of its stream.
pub type Feed = Receiver<io::Result<Option<Frame>>>;

/// Reads `input`'s frames on a thread of their own, for `run_fed`.
pub fn feed(mut input: impl Read + Send + 'static) -> Feed {
    let (frames, feed) = std::sync::mpsc::channel();
    std::thread::spawn(move || loop {
        let frame = crate::wire::read_frame(&mut input);
        let more = matches!(frame, Ok(Some(_)));
        if frames.send(frame).is_err() || !more {
            break;
        }
    });
    feed
}

/// The one Pong waiting for the writer, and when the writer is free for it.
#[derive(Default)]
pub(super) struct PongQueue {
    waiting: Option<(u64, Instant)>,
}

impl PongQueue {
    /// Queues the Pong to Ping `t`: one still waiting is dropped, and this one goes when it would.
    fn queue(&mut self, t: u64, now: Instant, wait: Duration) {
        let due = self.waiting.map_or(now + wait, |(_, due)| due);
        self.waiting = Some((t, due));
    }

    /// The waiting Pong's `t`, taken, once due by `now` (or at once with `now` None).
    fn take(&mut self, now: Option<Instant>) -> Option<u64> {
        let (t, due) = self.waiting?;
        if now.is_some_and(|now| now < due) {
            return None;
        }
        self.waiting = None;
        Some(t)
    }
}

impl<R: Read, W: Write> Session<'_, R, W> {
    /// Answers Ping `t`: at once, or through the queue with `--coalesce-pongs`.
    pub(super) fn pong(&mut self, t: u64) -> Result<(), String> {
        if self.feed.is_none() {
            if self.options.pong_delay > 0 {
                std::thread::sleep(Duration::from_millis(self.options.pong_delay));
            }
            return self.write_pong(t);
        }
        let wait = Duration::from_millis(self.options.coalesce_pongs);
        self.pongs.queue(t, Instant::now(), wait);
        Ok(())
    }

    /// Writes the waiting Pong if it is due by `now`, or at once with `now` None.
    pub(super) fn write_due_pong(&mut self, now: Option<Instant>) -> Result<(), String> {
        match self.pongs.take(now) {
            Some(t) => self.write_pong(t),
            None => Ok(()),
        }
    }

    fn write_pong(&mut self, t: u64) -> Result<(), String> {
        self.send(&ServerMsg::Pong { t, server_now_ms: super::now_ms() }, &[])
    }

    /// The client's next frame from the feed, writing the waiting Pong when it is due.
    pub(super) fn next_fed_frame(&mut self) -> Result<Option<Frame>, String> {
        loop {
            self.write_due_pong(Some(Instant::now()))?;
            let Some(feed) = &self.feed else { return Ok(None) };
            let next = match self.pongs.waiting {
                Some((_, due)) => match feed.recv_timeout(due.saturating_duration_since(Instant::now())) {
                    Err(RecvTimeoutError::Timeout) => continue,
                    other => other.ok(),
                },
                None => feed.recv().ok(),
            };
            // A feed gone without its end is an end too.
            return next.unwrap_or(Ok(None)).map_err(|e| format!("read failed: {e}"));
        }
    }
}
