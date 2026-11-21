//! Glifftop test tooling. `fixtures <dir>` writes the golden CBOR fixtures that the Swift
//! protocol tests check against; `planes <dir>` writes the synthetic pictures the video tests
//! check against; `serve <scenario>` is a scripted gliff-server on stdin/stdout for the
//! session tests.

mod acks;
mod fixtures;
mod planes;
mod serve;
mod wire;

use std::io::{self, BufWriter};
use std::path::Path;
use std::process::ExitCode;
use std::{env, fs};

fn usage() -> ExitCode {
    eprintln!(
        "usage: glifftop-fake-server fixtures <out-dir>\n       glifftop-fake-server planes <out-dir>\n       {}",
        serve::USAGE
    );
    ExitCode::from(2)
}

fn main() -> ExitCode {
    let args: Vec<String> = env::args().skip(1).collect();
    match args.as_slice() {
        [command, dir] if command == "fixtures" => {
            let cases = fixtures::cases().into_iter().map(|(name, body)| (format!("{name}.cbor"), body));
            write_cases(Path::new(dir), &["cbor"], cases.collect(), "fixtures")
        }
        [command, dir] if command == "planes" => {
            write_cases(Path::new(dir), &["nv12", "bgra"], planes::cases(), "plane files")
        }
        [command, rest @ ..] if command == "serve" => {
            let options = match serve::parse(rest) {
                Ok(options) => options,
                Err(error) => {
                    eprintln!("fake-server: {error}");
                    return usage();
                }
            };
            match serve::run(&options, io::stdin().lock(), BufWriter::new(io::stdout().lock())) {
                Ok(()) => ExitCode::SUCCESS,
                Err(error) => {
                    eprintln!("fake-server: {error}");
                    ExitCode::FAILURE
                }
            }
        }
        _ => usage(),
    }
}

fn write_cases(dir: &Path, extensions: &[&str], cases: Vec<(String, Vec<u8>)>, what: &str) -> ExitCode {
    match replace_files(dir, extensions, &cases) {
        Ok(()) => {
            eprintln!("wrote {} {what} to {}", cases.len(), dir.display());
            ExitCode::SUCCESS
        }
        Err(error) => {
            eprintln!("glifftop-fake-server: {error}");
            ExitCode::FAILURE
        }
    }
}

/// Replaces every file in `dir` with one of `extensions` by `cases`, so a removed case can't
/// linger. The cases are built before this runs: if one panics, the existing files are left
/// alone.
fn replace_files(dir: &Path, extensions: &[&str], cases: &[(String, Vec<u8>)]) -> std::io::Result<()> {
    fs::create_dir_all(dir)?;
    for entry in fs::read_dir(dir)? {
        let path = entry?.path();
        if path.extension().and_then(|ext| ext.to_str()).is_some_and(|ext| extensions.contains(&ext)) {
            fs::remove_file(path)?;
        }
    }
    for (name, body) in cases {
        fs::write(dir.join(name), body)?;
    }
    Ok(())
}
