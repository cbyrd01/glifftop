import Testing

@testable import GliffVideo

struct VideoFitTests {
    private func viewport(_ picture: (Int, Int), in drawable: (Int, Int), scaleToFit: Bool = false)
        -> VideoViewport
    {
        VideoFit.viewport(
            picture: PixelSize(width: picture.0, height: picture.1),
            drawable: PixelSize(width: drawable.0, height: drawable.1), scaleToFit: scaleToFit)
    }

    /// Scale to Fit grows a smaller picture until a side fills, aspect kept, centred.
    @Test func scaleToFitFillsALargerDrawable() {
        #expect(
            viewport((1280, 720), in: (2560, 1600), scaleToFit: true)
                == VideoViewport(x: 0, y: 80, width: 2560, height: 1440, isActualSize: false))
        #expect(
            viewport((1280, 720), in: (3000, 1440), scaleToFit: true)
                == VideoViewport(x: 220, y: 0, width: 2560, height: 1440, isActualSize: false))
    }

    /// A Standard virtual screen (half a side) fills a Retina window at twice.
    @Test func aHalfSizePictureFillsAtTwiceUnderScaleToFit() {
        #expect(
            viewport((1512, 982), in: (3024, 1964), scaleToFit: true)
                == VideoViewport(x: 0, y: 0, width: 3024, height: 1964, isActualSize: false))
    }

    /// A picture already filling a side stays 1:1, pixel for pixel.
    @Test func scaleToFitKeepsActualSizeWhenItFits() {
        #expect(
            viewport((2560, 1440), in: (2560, 1600), scaleToFit: true)
                == VideoViewport(x: 0, y: 80, width: 2560, height: 1440, isActualSize: true))
    }

    /// The server's rounding leaves a virtual screen (or a mirror fitted to the window) a few
    /// pixels short: still 1:1, never resampled by a fraction of a percent.
    @Test func scaleToFitLeavesANearFitOneToOne() {
        #expect(
            viewport((1598, 998), in: (1600, 1000), scaleToFit: true)
                == VideoViewport(x: 1, y: 1, width: 1598, height: 998, isActualSize: true))
        #expect(viewport((1586, 986), in: (1600, 1000), scaleToFit: true).isActualSize)
        #expect(!viewport((1580, 980), in: (1600, 1000), scaleToFit: true).isActualSize)
    }

    /// A picture with no area isn't shown at actual size, whatever its other side.
    @Test func aPictureWithNoAreaIsNotActualSize() {
        #expect(!viewport((0, 2000), in: (100, 100)).isActualSize)
    }

    @Test func scaleToFitStillScalesDown() {
        #expect(
            viewport((2560, 1440), in: (1280, 900), scaleToFit: true)
                == viewport((2560, 1440), in: (1280, 900)))
    }

    @Test func withoutScaleToFitNothingGrows() {
        #expect(
            viewport((1280, 720), in: (2560, 1600))
                == VideoViewport(x: 640, y: 440, width: 1280, height: 720, isActualSize: true))
    }

    /// An empty picture or drawable is left as it is, never divided by.
    @Test func scaleToFitOfNothingIsNothing() {
        #expect(viewport((0, 0), in: (2560, 1600), scaleToFit: true).width == 0)
        #expect(viewport((1280, 720), in: (0, 0), scaleToFit: true).width == 0)
    }

    @Test func exactFitIsOneToOneAtTheOrigin() {
        #expect(
            viewport((192, 108), in: (192, 108))
                == VideoViewport(x: 0, y: 0, width: 192, height: 108, isActualSize: true))
    }

    /// A larger drawable shows the picture 1:1, centred: pillarbox and letterbox.
    @Test func largerDrawableCentresOneToOne() {
        #expect(
            viewport((192, 108), in: (200, 108))
                == VideoViewport(x: 4, y: 0, width: 192, height: 108, isActualSize: true))
        #expect(
            viewport((192, 108), in: (192, 120))
                == VideoViewport(x: 0, y: 6, width: 192, height: 108, isActualSize: true))
    }

    @Test func smallerDrawableScalesKeepingAspect() {
        #expect(
            viewport((2560, 1440), in: (1280, 900))
                == VideoViewport(x: 0, y: 90, width: 1280, height: 720, isActualSize: false))
    }

    /// Odd remainders floor, so the origin stays on a whole pixel.
    @Test func oddRemaindersFloor() {
        #expect(
            viewport((192, 108), in: (195, 111))
                == VideoViewport(x: 1, y: 1, width: 192, height: 108, isActualSize: true))
        #expect(
            viewport((200, 100), in: (99, 100))
                == VideoViewport(x: 0, y: 25, width: 99, height: 49, isActualSize: false))
    }

    /// The limiting side fills the drawable exactly: no floating-point pixel lost to flooring.
    @Test func scaledSideFillsTheDrawable() {
        #expect(
            viewport((1062, 600), in: (1000, 800))
                == VideoViewport(x: 0, y: 118, width: 1000, height: 564, isActualSize: false))
        for width in 1001...1400 {
            let fit = viewport((width, 600), in: (1000, 800))
            #expect(fit.width == 1000, "\(width)×600: \(fit.width) wide")
        }
    }

    /// A fitted size lands on whole backing pixels: 1001 × 563.0625 points @2 → 1001 × 563.
    @Test func fittedContentSizeIsWholeBackingPixels() {
        let size = VideoFit.contentSize(
            view: PixelSize(width: 2560, height: 1440), backingScale: 2, available: (width: 1001, height: 700)
        )
        #expect(size.width == 1001 && size.height == 563 && !size.isActualSize)
    }

    /// The limiting side fills the available space exactly, with no floating-point pixel lost.
    @Test func fittedLimitingSideIsExact() {
        for available in stride(from: 400.0, through: 1280, by: 0.5) {
            let size = VideoFit.contentSize(
                view: PixelSize(width: 3840, height: 2160), backingScale: 2,
                available: (width: available, height: 5000))
            #expect(size.width == available, "available \(available): \(size.width)")
        }
    }

    /// A window not yet on a screen can report a backing scale of 0: treat it as 1.
    @Test func zeroBackingScaleCountsAsOne() {
        let size = VideoFit.contentSize(
            view: PixelSize(width: 1280, height: 720), backingScale: 0, available: (width: 1440, height: 900))
        #expect(size.width == 1280 && size.height == 720 && size.isActualSize)
    }

    @Test func contentSizeIsActualPointsWhenItFits() {
        let size = VideoFit.contentSize(
            view: PixelSize(width: 2560, height: 1440), backingScale: 2, available: (width: 1440, height: 900)
        )
        #expect(size.width == 1280 && size.height == 720 && size.isActualSize)
    }

    @Test func contentSizeShrinksKeepingAspectWhenItDoesnt() {
        let size = VideoFit.contentSize(
            view: PixelSize(width: 2560, height: 1440), backingScale: 2, available: (width: 1000, height: 700)
        )
        #expect(size.width == 1000 && size.height == 562.5 && !size.isActualSize)
    }
}
