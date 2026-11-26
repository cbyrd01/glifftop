import Testing

@testable import GliffFiles

@Suite struct RemotePathTests {
    func name(_ text: String) throws -> RemoteName { try #require(RemoteName(raw: Array(text.utf8))) }

    @Test func onlyAnAbsolutePathWithoutNULIsAccepted() {
        #expect(RemotePath(absolute: Array("/home/person".utf8)) != nil)
        #expect(RemotePath(absolute: Array("home/person".utf8)) == nil)
        #expect(RemotePath(absolute: Array("/home\u{0}x".utf8)) == nil)
        #expect(RemotePath(absolute: []) == nil)
        #expect(RemotePath(absolute: Array("/home/../etc".utf8)) == nil)
    }

    @Test func joiningTakesAValidatedName() throws {
        let home = try #require(RemotePath(absolute: Array("/home/person".utf8)))
        #expect(home.appending(try name("Downloads")).raw == Array("/home/person/Downloads".utf8))
        #expect(RemotePath.root.appending(try name("tmp")).raw == Array("/tmp".utf8))
    }

    @Test func goingUpTrimsTheLastComponent() throws {
        let path = try #require(RemotePath(absolute: Array("/home/person/".utf8)))
        #expect(path.parent.raw == Array("/home".utf8))
        #expect(path.parent.parent == .root)
        #expect(RemotePath.root.parent == .root)
    }

    @Test func componentsAreNames() throws {
        let path = try #require(RemotePath(absolute: Array("//home/./person".utf8)))
        #expect(path.components == [try name("home"), try name("person")])
        #expect(path.name == (try name("person")))
        #expect(RemotePath.root.name == nil)
    }
}
