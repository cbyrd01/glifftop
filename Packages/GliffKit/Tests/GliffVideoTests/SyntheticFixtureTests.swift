import Testing

struct SyntheticFixtureTests {
    @Test func planeSetsArePresent() {
        #expect(!SyntheticFixtures.names.isEmpty)
    }

    /// Each set's files are there at the size its name gives.
    @Test(arguments: SyntheticFixtures.names)
    func everyPlaneSetLoads(name: String) throws {
        _ = try SyntheticFixtures.planes(name)
    }

    /// Dual420 exists for 1-px chroma detail, which Single420 loses: the loader must keep the
    /// two expected pictures apart.
    @Test func fineDetailNeedsDual420() throws {
        let set = try SyntheticFixtures.planes("fine-192x108")
        #expect(set.expected != set.expectedSingle)
    }

    /// Every plane set has its encoded stream: 8 access units per plane.
    @Test(arguments: SyntheticFixtures.names)
    func everyPlaneSetHasAStream(name: String) throws {
        for plane in [SyntheticFixtures.Plane.main, .aux] {
            let units = try SyntheticFixtures.stream(name, plane: plane)
            #expect(units.count == 8)  // encode-fixtures' frameCount
            #expect(units.allSatisfy { !$0.isEmpty })
        }
    }
}
