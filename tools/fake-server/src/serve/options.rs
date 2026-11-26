//! The `serve` command line.

use gliff_proto::ChromaMode;
use std::path::Path;

pub const USAGE: &str = "glifftop-fake-server serve <scenario> [--chroma single|dual] [--frames N] \
     [--feature NAME]... [--expect-bye] [--mid-frame]\n  \
     stream only: [--streams DIR] [--size WxH]\n  input only: [--keymap-first] [--expect-keys N] [--expect-pointer N] [--expect-nudge] [--pong-delay MS] [--coalesce-pongs MS]\n  \
     cursor only: [--valid-only]\n  resize only: [--headless] [--expect-resizes N]\n  \
     clipboard-offer only: [--hostile]\n  \
     scenarios: handshake ping-first stream config-change error <code> hello-version drop \
     garbage silent feature skip stall <ms> input cursor resize clipboard-offer clipboard-request";

#[derive(Debug, PartialEq)]
pub enum Scenario {
    Handshake,
    PingFirst,
    Stream,
    ConfigChange,
    Error(u16),
    HelloVersion,
    Drop,
    Garbage,
    Silent,
    Feature,
    Skip,
    /// Streams, then sends nothing for this many milliseconds, then streams again.
    Stall(u64),
    /// Streams two frames, then checks the client's input (keys, keymap, pointer) until Bye or EOF.
    Input,
    /// After the StreamConfig, a valid cursor shape (id 7, its frame four bytes longer than
    /// it declares), one with its hotspot outside (8) and one with its pixels a byte short
    /// (9), or with `--valid-only` the first alone; then two frames.
    Cursor,
    /// Streams two frames, then answers each Resize as upstream's server does (a mirror, or
    /// a virtual screen with `--headless`) until Bye or EOF.
    Resize,
    /// Streams two frames, offers text, HTML and a PNG, and serves each request until Bye or
    /// EOF (`--hostile`: a stray chunk first and an HTML chunk over the limit, which the client
    /// must abort).
    ClipboardOffer,
    /// Streams two frames, then reads the client's offer at once: the text in order within the
    /// window, then refusals for a stale serial and an odd id.
    ClipboardRequest,
}

#[derive(Debug, PartialEq)]
pub struct Options {
    pub scenario: Scenario,
    pub chroma: ChromaMode,
    pub frames: Option<u64>,
    pub features: Vec<String>,
    pub expect_bye: bool,
    pub mid_frame: bool,
    /// Real access units to send instead of placeholders (`--streams`).
    pub streams: Option<Streams>,
    /// The StreamConfig's size (`--size`).
    pub size: Option<(u32, u32)>,
    /// `input`: a Key before any Keymap fails (`--keymap-first`).
    pub keymap_first: bool,
    /// `input`: fewer Key messages than this fails (`--expect-keys`).
    pub expect_keys: u64,
    /// `input`: fewer pointer messages (motion, button, axis) than this fails (`--expect-pointer`).
    pub expect_pointer: u64,
    /// `input`: two motions 1 apart on x, at the same y, must come before any key, button or
    /// scroll (`--expect-nudge`).
    pub expect_nudge: bool,
    /// `input`: each Pong waits this many milliseconds, and nothing is read meanwhile
    /// (`--pong-delay`): a server busy before it answers.
    pub pong_delay: u64,
    /// `input`: each Pong waits this many milliseconds from when it is queued, input still
    /// read, and a newer Pong replaces one waiting (`--coalesce-pongs`), as upstream's writer.
    pub coalesce_pongs: u64,
    /// `cursor`: only the valid shape (`--valid-only`).
    pub valid_only: bool,
    /// `resize`: the session is a virtual screen (`--headless`).
    pub headless: bool,
    /// `resize`: fewer Resize messages than this fails (`--expect-resizes`).
    pub expect_resizes: u64,
    /// `clipboard-offer`: the hostile variant (`--hostile`).
    pub hostile: bool,
}

/// `NNN.main.h264` (and `NNN.aux.h264` for Dual420) from a folder, frame 0 on, as
/// encode-fixtures writes them. Frame 0 is the keyframe.
#[derive(Debug, PartialEq)]
pub struct Streams {
    /// (main, aux) per frame; aux is empty for Single420.
    pub frames: Vec<(Vec<u8>, Vec<u8>)>,
}

impl Streams {
    fn read(dir: &Path, chroma: ChromaMode) -> Result<Self, String> {
        let file = |index: usize, plane: &str| dir.join(format!("{index:03}.{plane}.h264"));
        let read = |path: &Path| std::fs::read(path).map_err(|e| format!("{}: {e}", path.display()));
        let mut frames = Vec::new();
        loop {
            // The first missing main file ends the stream; any other error is an error.
            let path = file(frames.len(), "main");
            let main = match std::fs::read(&path) {
                Ok(main) => main,
                Err(e) if e.kind() == std::io::ErrorKind::NotFound => break,
                Err(e) => return Err(format!("{}: {e}", path.display())),
            };
            let aux = match chroma {
                ChromaMode::Dual420 => read(&file(frames.len(), "aux"))?,
                _ => Vec::new(),
            };
            frames.push((main, aux));
        }
        if frames.is_empty() {
            return Err(format!("no 000.main.h264 in {}", dir.display()));
        }
        Ok(Streams { frames })
    }

    pub fn len(&self) -> u64 {
        self.frames.len() as u64
    }
}

/// Parses the arguments after `serve`.
pub fn parse(args: &[String]) -> Result<Options, String> {
    let mut args = args.iter();
    let scenario = match args.next().map(String::as_str) {
        Some("handshake") => Scenario::Handshake,
        Some("ping-first") => Scenario::PingFirst,
        Some("stream") => Scenario::Stream,
        Some("config-change") => Scenario::ConfigChange,
        Some("error") => {
            let code = args.next().ok_or("error needs a code")?;
            Scenario::Error(code.parse().map_err(|_| format!("bad error code {code}"))?)
        }
        Some("hello-version") => Scenario::HelloVersion,
        Some("drop") => Scenario::Drop,
        Some("garbage") => Scenario::Garbage,
        Some("silent") => Scenario::Silent,
        Some("feature") => Scenario::Feature,
        Some("skip") => Scenario::Skip,
        Some("stall") => {
            let ms = args.next().ok_or("stall needs milliseconds")?;
            Scenario::Stall(ms.parse().map_err(|_| format!("bad stall {ms}"))?)
        }
        Some("input") => Scenario::Input,
        Some("cursor") => Scenario::Cursor,
        Some("resize") => Scenario::Resize,
        Some("clipboard-offer") => Scenario::ClipboardOffer,
        Some("clipboard-request") => Scenario::ClipboardRequest,
        Some(other) => return Err(format!("unknown scenario {other}")),
        None => return Err("no scenario".into()),
    };
    let mut options = Options {
        scenario,
        chroma: ChromaMode::Dual420,
        frames: None,
        features: Vec::new(),
        expect_bye: false,
        mid_frame: false,
        streams: None,
        size: None,
        keymap_first: false,
        expect_keys: 0,
        expect_pointer: 0,
        expect_nudge: false,
        pong_delay: 0,
        coalesce_pongs: 0,
        valid_only: false,
        headless: false,
        expect_resizes: 0,
        hostile: false,
    };
    let mut streams_dir = None;
    let mut input_flags = false;
    while let Some(flag) = args.next() {
        let mut value = || args.next().ok_or(format!("{flag} needs a value"));
        match flag.as_str() {
            "--chroma" => {
                options.chroma = match value()?.as_str() {
                    "single" => ChromaMode::Single420,
                    "dual" => ChromaMode::Dual420,
                    other => return Err(format!("bad chroma {other}")),
                }
            }
            "--frames" => {
                let n = value()?;
                options.frames = Some(n.parse().map_err(|_| format!("bad frame count {n}"))?);
            }
            "--feature" => options.features.push(value()?.clone()),
            "--expect-bye" => options.expect_bye = true,
            "--mid-frame" => options.mid_frame = true,
            "--streams" => streams_dir = Some(value()?.clone()),
            "--size" => {
                let size = value()?;
                let sides = size.split_once('x').and_then(|(w, h)| Some((w.parse().ok()?, h.parse().ok()?)));
                options.size = Some(sides.filter(|&(w, h)| w > 0 && h > 0).ok_or(format!("bad size {size}"))?);
            }
            "--keymap-first" => {
                options.keymap_first = true;
                input_flags = true;
            }
            "--expect-keys" => {
                input_flags = true;
                let n = value()?;
                options.expect_keys = n.parse().map_err(|_| format!("bad key count {n}"))?;
            }
            "--expect-pointer" => {
                input_flags = true;
                let n = value()?;
                options.expect_pointer = n.parse().map_err(|_| format!("bad pointer count {n}"))?;
            }
            "--expect-nudge" => {
                options.expect_nudge = true;
                input_flags = true;
            }
            "--pong-delay" => {
                input_flags = true;
                let ms = value()?;
                options.pong_delay = ms.parse().map_err(|_| format!("bad pong delay {ms}"))?;
            }
            "--coalesce-pongs" => {
                input_flags = true;
                let ms = value()?;
                options.coalesce_pongs = ms.parse().map_err(|_| format!("bad pong wait {ms}"))?;
            }
            "--valid-only" => options.valid_only = true,
            "--hostile" => options.hostile = true,
            "--headless" => options.headless = true,
            "--expect-resizes" => {
                let n = value()?;
                options.expect_resizes = n.parse().map_err(|_| format!("bad resize count {n}"))?;
            }
            other => return Err(format!("unknown flag {other}")),
        }
    }
    if (streams_dir.is_some() || options.size.is_some()) && options.scenario != Scenario::Stream {
        return Err("--streams and --size work with the stream scenario only".into());
    }
    if input_flags && options.scenario != Scenario::Input {
        return Err(
            "--keymap-first, --expect-keys, --expect-pointer, --expect-nudge, --pong-delay and --coalesce-pongs work with the input scenario only"
                .into()
        );
    }
    if options.pong_delay > 0 && options.coalesce_pongs > 0 {
        return Err("--pong-delay and --coalesce-pongs don't go together".into());
    }
    if options.valid_only && options.scenario != Scenario::Cursor {
        return Err("--valid-only works with the cursor scenario only".into());
    }
    if (options.headless || options.expect_resizes > 0) && options.scenario != Scenario::Resize {
        return Err("--headless and --expect-resizes work with the resize scenario only".into());
    }
    if options.hostile && options.scenario != Scenario::ClipboardOffer {
        return Err("--hostile works with the clipboard-offer scenario only".into());
    }
    // These scenarios always stream two frames and end at Bye or EOF.
    let fixed = matches!(
        options.scenario,
        Scenario::Input | Scenario::Resize | Scenario::ClipboardOffer | Scenario::ClipboardRequest
    );
    if fixed && (options.frames.is_some() || options.expect_bye) {
        return Err("--frames and --expect-bye don't work with the input, resize or clipboard scenarios".into());
    }
    if let Some(dir) = streams_dir {
        let streams = Streams::read(Path::new(&dir), options.chroma)?;
        if let Some(frames) = options.frames.filter(|&n| n > streams.len()) {
            return Err(format!("--frames {frames}, but {dir} has {} frames", streams.len()));
        }
        options.streams = Some(streams);
    }
    Ok(options)
}
