import Testing

@testable import GliffTransport

/// Whatever `hyprctl -j monitors` prints on the host, read as untrusted.
@Suite struct ScreenListParserTests {
    private func parse(_ json: String) throws(ScreenListError) -> [RemoteScreen] {
        try ScreenListParser.screens(from: Array(json.utf8))
    }

    private func monitor(
        _ name: String, width: Int = 2560, height: Int = 1440, extra: String = ""
    ) -> String {
        """
        {"name": "\(name)", "make": "LG Electronics", "model": "LG ULTRAGEAR", "width": \(width),
         "height": \(height), "scale": 1.00\(extra)}
        """
    }

    @Test func twoMonitorsOneFocused() throws {
        let screens = try parse(
            "[\(monitor("DP-2", extra: #", "focused": true"#)), \(monitor("DP-3", width: 1920, height: 1080))]"
        )
        #expect(
            screens == [
                RemoteScreen(
                    name: "DP-2", description: "LG Electronics LG ULTRAGEAR", width: 2560, height: 1440,
                    scale: 1, isFocused: true),
                RemoteScreen(
                    name: "DP-3", description: "LG Electronics LG ULTRAGEAR", width: 1920, height: 1080,
                    scale: 1, isFocused: false),
            ])
    }

    @Test func theSerialNeverShows() throws {
        let extra = #", "description": "LG Electronics LG ULTRAGEAR 603BNDQ14594", "serial": "603BNDQ14594""#
        let screens = try parse("[\(monitor("DP-2", extra: extra))]")
        #expect(screens.count == 1)
        #expect(!screens[0].description.contains("603BNDQ14594"))
        #expect(!screens[0].name.contains("603BNDQ14594"))
    }

    @Test func controlCharactersLeaveTheDescription() throws {
        let json =
            #"[{"name": "DP-2", "make": "LG\n\u202Eevil", "model": " M\u0007 ", "width": 1, "height": 1, "scale": 1}]"#
        #expect(try parse(json).map(\.description) == ["LGevil M"])
    }

    @Test func lineSeparatorsLeaveTheDescription() throws {
        let json =
            #"[{"name": "DP-2", "make": "LG\u2028DP-1", "model": "X\u2029Y", "width": 1, "height": 1, "scale": 1}]"#
        #expect(try parse(json).map(\.description) == ["LGDP-1 XY"])
    }

    @Test func combiningMarksCantFloodTheDescription() throws {
        let flood = "A" + String(repeating: "\\u0301", count: 5000)
        let json =
            #"[{"name": "DP-2", "make": ""# + flood
            + #"", "model": "", "width": 1, "height": 1, "scale": 1}]"#
        let screens = try parse(json)
        #expect(screens.count == 1)
        #expect(screens[0].description.unicodeScalars.count <= 201)
    }

    /// The cap is on the whole description, not on make and model each.
    @Test func aLongMakeAndModelAreCappedTogether() throws {
        let long = String(repeating: "x", count: 300)
        let json =
            #"[{"name": "DP-2", "make": ""# + long + #"", "model": ""# + long
            + #"", "width": 1, "height": 1, "scale": 1}]"#
        let description = try #require(try parse(json).first).description
        #expect(description.count == 201 && description.hasSuffix("x…"))
    }

    @Test func aRepeatedNameIsListedOnce() throws {
        let screens = try parse("[\(monitor("DP-2", width: 1920)), \(monitor("DP-2")), \(monitor("DP-3"))]")
        #expect(screens.map(\.name) == ["DP-2", "DP-3"])
        #expect(screens[0].width == 1920)
    }

    @Test(arguments: ["0.1", "11", "1e308", "-1", "0"])
    func anImpossibleScaleIsSkipped(scale: String) throws {
        let bad =
            #"{"name": "DP-2", "make": "A", "model": "B", "width": 1, "height": 1, "scale": "# + scale + "}"
        #expect(try parse("[\(bad), \(monitor("DP-3"))]").map(\.name) == ["DP-3"])
    }

    /// A gliff-server virtual screen (upstream names it `gliff-<pid>`; this session's or
    /// another's) goes when its session ends: not a monitor to mirror. Other headless outputs
    /// (Hyprland's own `HEADLESS-n`) stay.
    @Test func gliffVirtualScreensAreLeftOut() throws {
        let screens = try parse(
            "[\(monitor("gliff-4242")), \(monitor("DP-3")), \(monitor("gliff-display")), \(monitor("HEADLESS-2"))]"
        )
        #expect(screens.map(\.name) == ["DP-3", "gliff-display", "HEADLESS-2"])
    }

    @Test func aDisabledMonitorIsLeftOut() throws {
        let screens = try parse("[\(monitor("DP-2", extra: #", "disabled": true"#)), \(monitor("DP-3"))]")
        #expect(screens.map(\.name) == ["DP-3"])
    }

    @Test func aRotatedMonitorSwapsItsSides() throws {
        let screens = try parse(
            "[\(monitor("DP-2", extra: #", "transform": 1"#)), \(monitor("DP-3", extra: #", "transform": 2"#))]"
        )
        #expect(screens.map(\.width) == [1440, 2560])
        #expect(screens.map(\.height) == [2560, 1440])
    }

    @Test func anEmptyListIsEmpty() throws {
        #expect(try parse("[]").isEmpty)
    }

    @Test func unknownFieldsAreIgnored() throws {
        let screens = try parse(
            "[\(monitor("DP-2", extra: #", "activeWorkspace": {"id": 1}, "vrr": false"#))]")
        #expect(screens.map(\.name) == ["DP-2"])
    }

    @Test(arguments: [
        "DP 2", "a'b", String(repeating: "A", count: 65), "", "DP-2;reboot", "Ð",
        // gliff-server would read these as options, or `auto` as the focused monitor.
        "--help", "-x", "--headless", "auto",
    ])
    func aBadNameIsSkipped(name: String) throws {
        let quoted = name.replacing("\"", with: "\\\"")
        let screens = try parse("[\(monitor(quoted)), \(monitor("DP-3"))]")
        #expect(screens.map(\.name) == ["DP-3"])
    }

    @Test func aMissingFieldIsSkipped() throws {
        let screens = try parse(#"[{"name": "DP-2", "width": 2560}, "# + monitor("DP-3") + "]")
        #expect(screens.map(\.name) == ["DP-3"])
    }

    @Test(arguments: [0, -1, 16385])
    func anImpossibleSizeIsSkipped(width: Int) throws {
        let screens = try parse("[\(monitor("DP-2", width: width)), \(monitor("DP-3"))]")
        #expect(screens.map(\.name) == ["DP-3"])
    }

    @Test func notJSONIsUnreadable() {
        #expect(throws: ScreenListError.unreadable) { try parse("no Hyprland here") }
        #expect(throws: ScreenListError.unreadable) { try parse("") }
    }

    @Test func anObjectIsUnreadable() {
        #expect(throws: ScreenListError.unreadable) { try parse(monitor("DP-2")) }
    }

    @Test func wrongTypesSkipThatMonitor() throws {
        let bad = #"{"name": "DP-2", "make": "x", "model": "y", "width": "2560", "height": 1440, "scale": 1}"#
        let screens = try parse("[\(bad), \(monitor("DP-3")), 7, null]")
        #expect(screens.map(\.name) == ["DP-3"])
    }

    @Test func deeplyNestedIsUnreadable() {
        let nested = String(repeating: "[", count: 10_000) + String(repeating: "]", count: 10_000)
        #expect(throws: ScreenListError.unreadable) { try parse(nested) }
    }

    /// Each monitor's top-left in the host's layout, negative ones too.
    @Test func positionsAreRead() throws {
        let screens = try parse(
            "[\(monitor("DP-3", extra: #", "x": 0, "y": 0"#)), \(monitor("DP-2", extra: #", "x": 2560, "y": 0"#)), "
                + "\(monitor("HDMI-A-1", extra: #", "x": -1920, "y": -360"#))]")
        #expect(screens.map(\.x) == [0, 2560, -1920])
        #expect(screens.map(\.y) == [0, 0, -360])
    }

    /// A position missing, fractional, a string or out of range reads as none: the monitor is
    /// still listed.
    @Test(arguments: [#", "x": 1.5"#, #", "x": "0""#, #", "x": 2000000"#, #", "x": -1048577"#, ""])
    func aBadPositionReadsAsNil(_ field: String) throws {
        let screens = try parse("[\(monitor("DP-2", extra: field + #", "y": 0"#))]")
        #expect(screens.map(\.name) == ["DP-2"])
        #expect(screens.first?.x == nil)
        #expect(screens.first?.y == 0)
    }

    @Test func theEdgesOfTheRangeAreKept() throws {
        let screens = try parse("[\(monitor("DP-2", extra: #", "x": -1048576, "y": 1048576"#))]")
        #expect(screens.first?.x == -1_048_576)
        #expect(screens.first?.y == 1_048_576)
    }

    @Test func moreThanAMebibyteIsTooLarge() {
        let bytes = [UInt8](repeating: UInt8(ascii: " "), count: ScreenListParser.maxBytes + 1)
        #expect(throws: ScreenListError.tooLarge) { try ScreenListParser.screens(from: bytes) }
    }
}
