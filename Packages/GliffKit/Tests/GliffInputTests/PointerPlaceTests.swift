import Testing

@testable import GliffInput

/// Where a ⌘ event happened, from what the app's probe found there.
@Suite struct PointerPlaceTests {
    typealias Facts = PointerPlace.Facts

    private static let windows: [Facts.Window] = [
        .keySession(inVideoView: true), .keySession(inVideoView: false), .attachedToKeySession, .otherOfOurs,
        .notOurs,
    ]

    @Test(arguments: windows)
    func aDragFromThePictureIsThePicture(_ window: Facts.Window) {
        #expect(PointerPlace.classify(Facts(dragFromPicture: true, window: window)) == .picture)
        #expect(
            PointerPlace.classify(Facts(dragFromPicture: true, window: window, inMenuBarStrip: true))
                == .picture)
    }

    @Test func theVideoViewIsThePicture() {
        #expect(PointerPlace.classify(Facts(window: .keySession(inVideoView: true))) == .picture)
    }

    @Test func elsewhereInTheKeyWindowIsTheChrome() {
        #expect(PointerPlace.classify(Facts(window: .keySession(inVideoView: false))) == .chrome)
    }

    @Test func aPopoverIsTheChrome() {
        #expect(PointerPlace.classify(Facts(window: .attachedToKeySession)) == .chrome)
    }

    @Test func anotherSessionWindowOrSettingsIsOutside() {
        #expect(PointerPlace.classify(Facts(window: .otherOfOurs)) == .outside)
    }

    @Test(arguments: [Facts.Window.notOurs, .otherOfOurs])
    func theMenuBarIsTheChrome(_ window: Facts.Window) {
        #expect(PointerPlace.classify(Facts(window: window, inMenuBarStrip: true)) == .chrome)
    }

    /// The key session window under the strip (the menu bar not there: a shown or revealed one
    /// has its own window over it) is the picture.
    @Test func theStripOverThePictureIsThePicture() {
        #expect(
            PointerPlace.classify(Facts(window: .keySession(inVideoView: true), inMenuBarStrip: true))
                == .picture)
    }

    @Test func anotherAppIsOutside() {
        #expect(PointerPlace.classify(Facts(window: .notOurs)) == .outside)
    }
}
