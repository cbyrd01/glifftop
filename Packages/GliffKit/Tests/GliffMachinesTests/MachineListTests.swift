import Foundation
import GliffSession
import GliffTransport
import Testing

@testable import GliffMachines

/// The saved machines: each destination once, with the options it last connected with,
/// favourites first, then the most recent.
@Suite struct MachineListTests {
    private let day = Date(timeIntervalSinceReferenceDate: 800_000_000)

    @Test func connectingAddsAMachineNamedForItsDestination() {
        var list = MachineList(data: nil)
        let machine = list.connected("user@omarchy", options: MachineOptions(screen: .virtual), at: day)
        #expect(list.machines == [machine])
        #expect(machine.name == "user@omarchy")
        #expect(machine.destination == "user@omarchy")
        #expect(machine.options.screen == .virtual)
        #expect(machine.lastConnected == day)
        #expect(!machine.isFavorite)
    }

    @Test func connectingAgainUpdatesTheSameMachine() {
        var list = MachineList(data: nil)
        var first = list.connected("omarchy", options: MachineOptions(), at: day)
        first.name = "Desk"
        list.save(first)
        let later = day.addingTimeInterval(60)
        let again = list.connected("omarchy", options: MachineOptions(textSize: .f75), at: later)
        #expect(list.machines.count == 1)
        #expect(again.id == first.id)
        #expect(again.name == "Desk")
        #expect(again.options.textSize == .f75)
        #expect(again.lastConnected == later)
    }

    @Test func destinationsAreTrimmed() {
        var list = MachineList(data: nil)
        list.connected("  omarchy\n", options: MachineOptions(), at: day)
        #expect(list.machines.first?.destination == "omarchy")
        #expect(list.machine(for: " omarchy ") != nil)
        #expect(list.machine(for: "omarch") == nil)
    }

    @Test func favouritesComeFirstThenTheMostRecent() {
        var list = MachineList(data: nil)
        list.connected("old", options: MachineOptions(), at: day)
        list.connected("new", options: MachineOptions(), at: day.addingTimeInterval(10))
        var star = list.connected("star", options: MachineOptions(), at: day.addingTimeInterval(-10))
        star.isFavorite = true
        list.save(star)
        let never = Machine(name: "b-never", destination: "b-never")
        let never2 = Machine(name: "a-never", destination: "a-never")
        list.save(never)
        list.save(never2)
        #expect(list.machines.map(\.destination) == ["star", "new", "old", "a-never", "b-never"])
    }

    @Test func saveReplacesById() {
        var list = MachineList(data: nil)
        var machine = list.connected("omarchy", options: MachineOptions(), at: day)
        machine.destination = "user@omarchy"
        list.save(machine)
        #expect(list.machines.map(\.destination) == ["user@omarchy"])
    }

    /// The sheet's copy was taken when it opened: what it doesn't show (the favourite, the last
    /// connection) is the stored machine's when it saves.
    @Test func anEditKeepsWhatTheSheetDoesntShow() {
        var list = MachineList(data: nil)
        var opened = list.connected("omarchy", options: MachineOptions(), at: day)
        var stored = opened
        stored.isFavorite = true
        list.save(stored)
        let later = day.addingTimeInterval(60)
        list.connected("omarchy", options: MachineOptions(), at: later)
        opened.name = "Desk"
        opened.options.textSize = .f75
        list.saveEdit(opened)
        let saved = list.machines.first
        #expect(saved?.name == "Desk")
        #expect(saved?.options.textSize == .f75)
        #expect(saved?.isFavorite == true)
        #expect(saved?.lastConnected == later)
    }

    @Test func removeRemoves() {
        var list = MachineList(data: nil)
        let machine = list.connected("omarchy", options: MachineOptions(), at: day)
        list.remove(id: machine.id)
        #expect(list.machines.isEmpty)
    }

    @Test func aRoundTripKeepsEverything() {
        var list = MachineList(data: nil)
        let options = MachineOptions(
            screen: .named("DP-2"), textSize: .f875, resolution: .standard, scaleToFit: true,
            reconnects: false)
        var machine = list.connected("omarchy", options: options, at: day)
        machine.isFavorite = true
        list.save(machine)
        list.connected("other", options: MachineOptions(screen: .virtual), at: day)
        #expect(MachineList(data: list.data()) == list)
    }

    @Test func anUnreadableEntryIsSkipped() throws {
        var list = MachineList(data: nil)
        list.connected("omarchy", options: MachineOptions(), at: day)
        var entries = try #require(try JSONSerialization.jsonObject(with: list.data()) as? [[String: Any]])
        var broken = entries[0]
        broken.removeValue(forKey: "destination")
        broken["id"] = UUID().uuidString
        entries.insert(broken, at: 0)
        let data = try JSONSerialization.data(withJSONObject: entries)
        #expect(MachineList(data: data).machines.map(\.destination) == ["omarchy"])
    }

    @Test func dataThatIsNoListGivesNone() {
        #expect(MachineList(data: Data("{}".utf8)).machines.isEmpty)
        #expect(MachineList(data: Data([0xff])).machines.isEmpty)
    }

    /// Options stored by another version: what's missing or unreadable takes its default.
    @Test func aMissingOptionTakesItsDefault() throws {
        let json = #"{"screen": {"virtual": {}}, "textSize": 3, "scaleToFit": true}"#
        let options = try JSONDecoder().decode(MachineOptions.self, from: Data(json.utf8))
        #expect(options == MachineOptions(screen: .virtual, scaleToFit: true))
    }

    @Test func saveTrimsTheDestination() {
        var list = MachineList(data: nil)
        list.save(Machine(name: "Desk", destination: " omarchy\n"))
        #expect(list.machines.map(\.destination) == ["omarchy"])
        #expect(list.machine(for: "omarchy")?.name == "Desk")
    }

    /// Each destination once: a machine saved with another's destination takes its place.
    @Test func savingAnotherMachinesDestinationReplacesIt() {
        var list = MachineList(data: nil)
        let other = list.connected("omarchy", options: MachineOptions(), at: day)
        var edited = list.connected("work", options: MachineOptions(), at: day)
        edited.destination = "omarchy"
        list.save(edited)
        #expect(list.machines.map(\.id) == [edited.id])
        #expect(list.machine(for: "omarchy")?.id != other.id)
    }

    @Test func storedDuplicatesKeepTheFirst() throws {
        let first = Machine(name: "First", destination: "omarchy")
        let second = Machine(name: "Second", destination: " omarchy")
        let data = try JSONEncoder().encode([first, second])
        let list = MachineList(data: data)
        #expect(list.machines.map(\.name) == ["First"])
    }
}
