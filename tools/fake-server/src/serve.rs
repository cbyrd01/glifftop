//! `serve <scenario>`: a scripted gliff-server on stdin/stdout for Glifftop's session tests.
//! Messages are upstream gliff-proto's own types. A scenario fails (exit 1, one line on
//! stderr) unless the client behaves: the right Hello, exactly one FrameAck per video frame
//! in order, Pong for Ping, and Bye when asked for.

mod clipboard;
#[cfg(test)]
mod clipboard_tests;
mod cursor;
mod input;
mod messages;
mod options;
mod pongs;
#[cfg(test)]
mod pongs_tests;
mod read;
mod resize;
#[cfg(test)]
mod tests;

pub use options::{parse, Options, Scenario, USAGE};
pub use pongs::{feed, Feed};

use messages::{hello_ack, hello_ack_session, skippable};

use crate::acks::AckTracker;
use crate::wire::{body, write_frame};
use gliff_proto::{ChromaMode, ClientMsg, Codec, Rect, ServerMsg, VideoPipeline};
use std::io::{self, Read, Write};
use std::time::{SystemTime, UNIX_EPOCH};

/// Runs the scenario against a client on `input`/`output`.
pub fn run(options: &Options, input: impl Read, output: impl Write) -> Result<(), String> {
    play(Session::new(options, input, output, None))
}

/// `run`, the client's frames read from `feed` (`--coalesce-pongs`).
pub fn run_fed(options: &Options, feed: Feed, output: impl Write) -> Result<(), String> {
    play(Session::new(options, io::empty(), output, Some(feed)))
}

fn play<R: Read, W: Write>(mut session: Session<'_, R, W>) -> Result<(), String> {
    let options = session.options;
    // The banner goes out before anything else; the client may give up before its Hello.
    if options.scenario != Scenario::Garbage {
        session.read_hello()?;
    }
    match options.scenario {
        Scenario::Silent => session.drain(),
        Scenario::Garbage => {
            session.write_raw(b"Welcome to omarchy!\n")?;
            session.drain()
        }
        Scenario::Handshake => {
            session.send(&hello_ack(1, &[]), &[])?;
            session.end(true)
        }
        Scenario::PingFirst => {
            session.send(&hello_ack(1, &[]), &[])?;
            // As upstream: pipelined behind HelloAck, never waited on.
            session.send(&ServerMsg::Ping { t: 42 }, &[])?;
            session.stream_config(1280, 720, 60)?;
            session.frames(3, false)?;
            match session.recv()? {
                Some(ClientMsg::Pong { t: 42 }) => {}
                Some(other) => return Err(format!("expected Pong {{ t: 42 }} first, got {other:?}")),
                None => return Err("the client closed before sending Pong { t: 42 }".into()),
            }
            session.end(false)
        }
        Scenario::Stream => {
            session.send(&hello_ack(1, &[]), &[])?;
            let (width, height) = options.size.unwrap_or((1280, 720));
            session.stream_config(width, height, 60)?;
            // Real streams: every file unless --frames asks for fewer (never more: parse checks).
            let count = match &options.streams {
                Some(streams) => options.frames.unwrap_or(streams.len()),
                None => options.frames.unwrap_or(10),
            };
            session.frames(count, false)?;
            session.end(false)
        }
        Scenario::ConfigChange => {
            session.send(&hello_ack(1, &[]), &[])?;
            session.stream_config(1280, 720, 60)?;
            session.frames(3, false)?;
            session.stream_config(1280, 720, 30)?;
            session.frames(3, false)?;
            session.stream_config(1920, 1080, 30)?;
            session.frames(3, true)?;
            session.end(false)
        }
        Scenario::Error(code) => {
            let version = (code == 1).then_some(1);
            session.send(&ServerMsg::Error { code, message: "fake error".into(), version }, &[])?;
            session.drain()
        }
        Scenario::HelloVersion => {
            session.send(&hello_ack(2, &[]), &[])?;
            session.drain()
        }
        Scenario::Drop => {
            session.send(&hello_ack(1, &[]), &[])?;
            session.stream_config(1280, 720, 60)?;
            session.frames(2, false)?;
            if options.mid_frame {
                let frame = session.video_frame(3, false);
                session.write_raw(&frame[..frame.len() / 2])?;
            }
            Ok(())
        }
        Scenario::Feature => {
            session.send(&hello_ack(1, &options.features), &[])?;
            // [99, [7]] and [98, []]: variants no v0.4.3 client knows.
            session.write_body(&[0x82, 0x18, 99, 0x81, 7], &[&[1, 2, 3]])?;
            session.write_body(&[0x82, 0x18, 98, 0x80], &[&[4, 5]])?;
            session.stream_config(1280, 720, 60)?;
            session.frames(2, false)?;
            session.end(false)
        }
        Scenario::Stall(ms) => {
            session.send(&hello_ack(1, &[]), &[])?;
            session.stream_config(1280, 720, 60)?;
            session.frames(2, false)?;
            while session.acks.outstanding() > 0 {
                session.await_ack(false)?;
            }
            // Not a byte, Pongs included: the client's Pings wait unread in the pipe.
            std::thread::sleep(std::time::Duration::from_millis(ms));
            session.frames(1, false)?;
            session.end(true)
        }
        Scenario::Input => {
            session.send(&hello_ack(1, &[]), &[])?;
            session.stream_config(1280, 720, 60)?;
            session.frames(2, false)?;
            session.input()
        }
        Scenario::Resize => {
            session.send(&hello_ack_session(1, &[], options.headless), &[])?;
            session.stream_config(1280, 720, 60)?;
            session.frames(2, false)?;
            session.resize()
        }
        Scenario::Cursor => {
            session.send(&hello_ack(1, &[]), &[])?;
            session.stream_config(1280, 720, 60)?;
            session.cursor_shapes()?;
            session.frames(2, false)?;
            session.end(false)
        }
        Scenario::ClipboardOffer => {
            session.send(&hello_ack(1, &[]), &[])?;
            session.stream_config(1280, 720, 60)?;
            session.frames(2, false)?;
            session.clipboard_offer()
        }
        Scenario::ClipboardRequest => {
            session.send(&hello_ack(1, &[]), &[])?;
            session.stream_config(1280, 720, 60)?;
            session.frames(2, false)?;
            session.clipboard_request()
        }
        Scenario::Skip => {
            session.send(&hello_ack(1, &[]), &[])?;
            session.stream_config(1280, 720, 60)?;
            for (extra, payload) in skippable() {
                session.frames(1, false)?;
                session.write_body(&extra, &[&payload])?;
            }
            session.end(false)
        }
    }
}

/// Frames the client may leave un-acked before the fake waits for an ack: this test
/// server's own limit (upstream paces by bytes in flight instead).
const MAX_IN_FLIGHT: usize = 4;

struct Session<'a, R, W> {
    options: &'a Options,
    input: R,
    output: W,
    acks: AckTracker,
    last_frame_id: u64,
    size: (u32, u32),
    /// The client said Bye mid-stream (with `--expect-bye`): the scenario ends, writing nothing more.
    bye: bool,
    /// The client's frames, read on another thread (`--coalesce-pongs`); else from `input`.
    feed: Option<Feed>,
    pongs: pongs::PongQueue,
}

impl<'a, R: Read, W: Write> Session<'a, R, W> {
    fn new(options: &'a Options, input: R, output: W, feed: Option<Feed>) -> Self {
        Self {
            options,
            input,
            output,
            acks: AckTracker::new(),
            last_frame_id: 0,
            size: (0, 0),
            bye: false,
            feed,
            pongs: pongs::PongQueue::default(),
        }
    }

    fn write_raw(&mut self, bytes: &[u8]) -> Result<(), String> {
        if self.bye {
            return Ok(());
        }
        self.output.write_all(bytes).and_then(|()| self.output.flush()).map_err(write_failed)
    }

    fn write_body(&mut self, body: &[u8], payloads: &[&[u8]]) -> Result<(), String> {
        if self.bye {
            return Ok(());
        }
        write_frame(&mut self.output, body, payloads).map_err(write_failed)
    }

    fn send(&mut self, message: &ServerMsg, payloads: &[&[u8]]) -> Result<(), String> {
        self.write_body(&body(message), payloads)
    }

    fn read_hello(&mut self) -> Result<(), String> {
        let caps = match self.recv()? {
            Some(ClientMsg::Hello { version: 1, caps, .. }) => caps,
            Some(ClientMsg::Hello { version, .. }) => return Err(format!("Hello version {version}, expected 1")),
            Some(other) => return Err(format!("expected Hello first, got {other:?}")),
            None => return Err("the client closed before sending Hello".into()),
        };
        if caps.codecs != [Codec::H264] {
            return Err(format!("Hello codecs {:?}, expected [H264]", caps.codecs));
        }
        if caps.chroma != [ChromaMode::Dual420, ChromaMode::Single420] {
            return Err(format!("Hello chroma {:?}, expected [Dual420, Single420]", caps.chroma));
        }
        if caps.features != self.options.features {
            return Err(format!("Hello features {:?}, expected {:?}", caps.features, self.options.features));
        }
        Ok(())
    }

    /// Acts on one client message. Returns whether it was Bye.
    fn handle(&mut self, message: ClientMsg) -> Result<bool, String> {
        match message {
            ClientMsg::FrameAck { frame_id, .. } => self.acks.acked(frame_id)?,
            ClientMsg::Ping { t } => self.pong(t)?,
            ClientMsg::Bye => {
                self.write_due_pong(None)?;
                return Ok(true);
            }
            _ => {}
        }
        Ok(false)
    }

    /// Handles the next client message; the client closing or saying Bye here, with
    /// frames still un-acked, fails. `mid_stream`, a Bye with `--expect-bye` ends the
    /// scenario instead: a client disconnecting never sees the frames still in flight, and
    /// upstream's server just ends.
    fn await_ack(&mut self, mid_stream: bool) -> Result<(), String> {
        match self.recv()? {
            Some(message) => {
                if self.handle(message)? {
                    if mid_stream && self.options.expect_bye {
                        self.bye = true;
                        return Ok(());
                    }
                    self.acks.finish().map_err(|e| format!("Bye before every ack: {e}"))?;
                }
                Ok(())
            }
            None => self.acks.finish().and(Err("the client closed before acking".into())),
        }
    }

    fn stream_config(&mut self, width: u32, height: u32, fps_cap: u32) -> Result<(), String> {
        self.config(width, height, 1000, fps_cap)
    }

    /// A StreamConfig whose stream and view are both `width`×`height`.
    fn config(&mut self, width: u32, height: u32, scale_milli: u32, fps_cap: u32) -> Result<(), String> {
        self.size = (width, height);
        let config = ServerMsg::StreamConfig {
            codec: Codec::H264,
            chroma: self.options.chroma,
            pipeline: Some(VideoPipeline::Gpu),
            width,
            height,
            scale_milli,
            extradata: Vec::new(),
            aux_extradata: None,
            view_width: width,
            view_height: height,
            fps_cap,
        };
        self.send(&config, &[])
    }

    /// A video frame as written: header, message, payloads (main, then aux for Dual420). With
    /// `--streams`, frame `n` (from 1) carries file `n - 1`, and only the first is a keyframe;
    /// otherwise placeholders.
    fn video_frame(&self, frame_id: u64, force_keyframe: bool) -> Vec<u8> {
        let dual = self.options.chroma == ChromaMode::Dual420;
        let (main, aux, keyframe): (&[u8], &[u8], bool) = match &self.options.streams {
            Some(streams) => {
                let (main, aux) = &streams.frames[(frame_id - 1) as usize];
                (main, aux, frame_id == 1)
            }
            None => (&[0xA5; 1000], if dual { &[0x5A; 500] } else { &[] }, frame_id == 1 || frame_id.is_multiple_of(5)),
        };
        let (width, height) = self.size;
        let message = ServerMsg::VideoFrame {
            frame_id,
            pts_us: frame_id * 16_667,
            keyframe: force_keyframe || keyframe,
            damage: vec![Rect { x: 0, y: 0, width: width as i32, height: height as i32 }],
            data_len: main.len() as u32,
            aux_len: aux.len() as u32,
        };
        let mut frame = Vec::new();
        write_frame(&mut frame, &body(&message), &[main, aux]).expect("writing to a Vec cannot fail");
        frame
    }

    /// Sends `count` frames, waiting for acks whenever MAX_IN_FLIGHT are outstanding. The
    /// first is a keyframe if `keyframe_first`.
    fn frames(&mut self, count: u64, keyframe_first: bool) -> Result<(), String> {
        for n in 0..count {
            while self.acks.outstanding() >= MAX_IN_FLIGHT && !self.bye {
                self.await_ack(true)?;
            }
            if self.bye {
                return Ok(());
            }
            self.last_frame_id += 1;
            let frame = self.video_frame(self.last_frame_id, keyframe_first && n == 0);
            self.write_raw(&frame)?;
            self.acks.sent(self.last_frame_id);
        }
        Ok(())
    }

    /// After the last frame: every ack, then Bye if `--expect-bye` (or `bye_ok`), else EOF.
    fn end(&mut self, bye_ok: bool) -> Result<(), String> {
        if self.bye {
            return Ok(());
        }
        while self.acks.outstanding() > 0 {
            self.await_ack(false)?;
        }
        loop {
            match self.recv()? {
                Some(message) => {
                    if self.handle(message)? {
                        if self.options.expect_bye || bye_ok {
                            return Ok(());
                        }
                        return Err("unexpected Bye".into());
                    }
                }
                None if self.options.expect_bye => return Err("the client closed without Bye".into()),
                None => return self.acks.finish(),
            }
        }
    }
}

fn write_failed(error: io::Error) -> String {
    format!("write failed: {error}")
}

fn now_ms() -> u64 {
    SystemTime::now().duration_since(UNIX_EPOCH).map_or(0, |d| d.as_millis() as u64)
}
