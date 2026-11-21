//! Synthetic pictures for GliffVideo's tests, built with upstream gliff-proto v0.4.3's own
//! colour conversion and chroma split. For each image `<name>-<W>x<H>`:
//! - `.main.nv12`, `.aux.nv12`: the Dual420 planes (Y, then interleaved UV), as
//!   `split_yuv444` lays them out;
//! - `.bgra`: what a Dual420 client must show, `yuv444_to_bgra` of the full 4:4:4 picture;
//! - `.single.bgra`: what a Single420 client shows from the main plane alone.

use gliff_proto::chroma::{nv12_to_yuv444, split_yuv444, Nv12, Yuv444};
use gliff_proto::color::{bgra_to_yuv444, yuv444_to_bgra};

/// One synthetic picture, as BGRA.
pub struct Image {
    pattern: Pattern,
    width: usize,
    height: usize,
}

#[derive(Clone, Copy)]
enum Pattern {
    /// Eight 24-px vertical bars of pure colours: catches a red/blue swap.
    Bars,
    /// 1-px chroma detail that Single420 loses: a red/blue checkerboard on the left, alternating
    /// magenta/green columns on the right.
    Fine,
    /// Smooth ramps in all three channels.
    Gradient,
}

/// H.264 codes 16-row macroblocks, so 108 rows exercise the encoder's crop.
pub fn images() -> Vec<Image> {
    vec![
        Image { pattern: Pattern::Bars, width: 192, height: 108 },
        Image { pattern: Pattern::Fine, width: 192, height: 108 },
        Image { pattern: Pattern::Gradient, width: 192, height: 108 },
        Image { pattern: Pattern::Gradient, width: 256, height: 144 },
    ]
}

impl Image {
    pub fn name(&self) -> String {
        let pattern = match self.pattern {
            Pattern::Bars => "bars",
            Pattern::Fine => "fine",
            Pattern::Gradient => "gradient",
        };
        format!("{pattern}-{}x{}", self.width, self.height)
    }

    fn bgra(&self) -> Vec<u8> {
        let (w, h) = (self.width, self.height);
        let mut out = Vec::with_capacity(w * h * 4);
        for y in 0..h {
            for x in 0..w {
                let [b, g, r] = self.pixel(x, y);
                out.extend_from_slice(&[b, g, r, 255]);
            }
        }
        out
    }

    /// [B, G, R] at (x, y).
    fn pixel(&self, x: usize, y: usize) -> [u8; 3] {
        const WHITE: [u8; 3] = [255, 255, 255];
        const YELLOW: [u8; 3] = [0, 255, 255];
        const CYAN: [u8; 3] = [255, 255, 0];
        const GREEN: [u8; 3] = [0, 255, 0];
        const MAGENTA: [u8; 3] = [255, 0, 255];
        const RED: [u8; 3] = [0, 0, 255];
        const BLUE: [u8; 3] = [255, 0, 0];
        const BLACK: [u8; 3] = [0, 0, 0];
        match self.pattern {
            Pattern::Bars => [WHITE, YELLOW, CYAN, GREEN, MAGENTA, RED, BLUE, BLACK][(x / 24).min(7)],
            Pattern::Fine if x < self.width / 2 => if (x + y) % 2 == 0 { RED } else { BLUE },
            Pattern::Fine => if x % 2 == 0 { MAGENTA } else { GREEN },
            Pattern::Gradient => {
                let (w, h) = (self.width - 1, self.height - 1);
                let ramp = |n: usize, d: usize| (255 * n / d) as u8;
                [ramp(x, w), ramp(y, h), ramp(x + y, w + h)]
            }
        }
    }

    fn yuv(&self) -> Yuv444 {
        bgra_to_yuv444(&self.bgra(), self.width * 4, self.width, self.height)
    }
}

/// Every file, sorted by name: (file name, bytes).
pub fn cases() -> Vec<(String, Vec<u8>)> {
    let mut cases = Vec::new();
    for image in images() {
        let name = image.name();
        let source = image.yuv();
        let (main, aux) = split_yuv444(&source);
        cases.push((format!("{name}.aux.nv12"), nv12_bytes(&aux)));
        cases.push((format!("{name}.bgra"), yuv444_to_bgra(&source)));
        cases.push((format!("{name}.main.nv12"), nv12_bytes(&main)));
        cases.push((format!("{name}.single.bgra"), yuv444_to_bgra(&nv12_to_yuv444(&main))));
    }
    cases.sort_by(|a, b| a.0.cmp(&b.0));
    cases
}

fn nv12_bytes(planes: &Nv12) -> Vec<u8> {
    [planes.y.as_slice(), planes.uv.as_slice()].concat()
}

#[cfg(test)]
mod tests {
    use super::*;
    use gliff_proto::chroma::recombine_yuv444;

    #[test]
    fn cases_are_sorted_and_unique() {
        let names: Vec<String> = cases().into_iter().map(|(name, _)| name).collect();
        let mut sorted = names.clone();
        sorted.sort_unstable();
        sorted.dedup();
        assert_eq!(names, sorted);
        assert_eq!(names.len(), 16);
    }

    #[test]
    fn each_case_has_the_right_sizes() {
        for (name, body) in cases() {
            let image = images().into_iter().find(|i| name.starts_with(&i.name())).unwrap();
            let pixels = image.width * image.height;
            let expected = if name.ends_with(".nv12") { pixels * 3 / 2 } else { pixels * 4 };
            assert_eq!(body.len(), expected, "{name}");
        }
    }

    #[test]
    fn dual_planes_recombine_to_the_source() {
        for image in images() {
            let source = image.yuv();
            let (main, aux) = split_yuv444(&source);
            assert_eq!(recombine_yuv444(&main, &aux), source, "{}", image.name());
        }
    }

    /// Dual420 exists for 1-px chroma detail, which Single420 loses.
    #[test]
    fn fine_detail_needs_dual420() {
        let cases = cases();
        let file = |name: &str| &cases.iter().find(|(n, _)| n == name).unwrap().1;
        assert_ne!(file("fine-192x108.bgra"), file("fine-192x108.single.bgra"));
    }

    #[test]
    fn bars_red_is_red() {
        let (_, bgra) = cases().into_iter().find(|(name, _)| name == "bars-192x108.bgra").unwrap();
        let (x, y) = (5 * 24 + 12, 54);
        let pixel = &bgra[(y * 192 + x) * 4..][..4];
        for (got, want) in pixel.iter().zip([0u8, 0, 255, 255]) {
            assert!(got.abs_diff(want) <= 1, "{pixel:?}");
        }
    }
}
