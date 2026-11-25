import GliffSFTP
import Testing

@testable import GliffFiles

/// Every rule on a reply's shape, checked as it arrives, its request awaited or abandoned.
@Suite struct ExpectedReplyTests {
    @Test func aStatusOKAnswersOnlyARequestThatTakesNoValue() {
        #expect(ExpectedReply(.remove(path: [1])).allows(.status(id: 1, code: .ok)))
        #expect(
            !ExpectedReply(.open(path: [1], flags: .read, attributes: SFTPAttributes())).allows(
                .status(id: 1, code: .ok)))
        #expect(!ExpectedReply(.read(handle: [1], offset: 0, length: 4)).allows(.status(id: 1, code: .ok)))
        #expect(
            ExpectedReply(.read(handle: [1], offset: 0, length: 4)).allows(.status(id: 1, code: .endOfFile)))
    }

    @Test func dataIsNeverEmptyNorLongerThanAsked() {
        let read = ExpectedReply(.read(handle: [1], offset: 0, length: 4))
        #expect(read.allows(.data(id: 1, bytes: [1, 2, 3, 4])))
        #expect(!read.allows(.data(id: 1, bytes: [])))
        #expect(!read.allows(.data(id: 1, bytes: [1, 2, 3, 4, 5])))
    }

    @Test func namesAreNeverEmptyAndRealpathGivesOne() {
        let entry = SFTPNameEntry(name: [0x2F], attributes: SFTPAttributes())
        #expect(ExpectedReply(.readdir(handle: [1])).allows(.name(id: 1, entries: [entry, entry])))
        #expect(!ExpectedReply(.readdir(handle: [1])).allows(.name(id: 1, entries: [])))
        #expect(ExpectedReply(.realpath(path: [1])).allows(.name(id: 1, entries: [entry])))
        #expect(!ExpectedReply(.realpath(path: [1])).allows(.name(id: 1, entries: [entry, entry])))
        #expect(!ExpectedReply(.readlink(path: [1])).allows(.name(id: 1, entries: [])))
    }
}
