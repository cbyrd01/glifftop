import Testing

@testable import GliffClipboard

/// Share the clipboard, one setting of three, in order of what each sends.
@Suite struct ClipboardSharingTests {
    @Test func stepsGoOffSharedPasswordsOff() {
        #expect(ClipboardSharing.off.next == .shared)
        #expect(ClipboardSharing.shared.next == .withPasswords)
        #expect(ClipboardSharing.withPasswords.next == .off)
    }

    @Test func eachSendsMoreThanTheOneBefore() {
        #expect(ClipboardSharing.off.sendsLess(than: .shared))
        #expect(ClipboardSharing.shared.sendsLess(than: .withPasswords))
        #expect(!ClipboardSharing.withPasswords.sendsLess(than: .off))
        #expect(!ClipboardSharing.shared.sendsLess(than: .shared))
    }

    @Test func theTwoSwitchesMakeOne() {
        #expect(ClipboardSharing(share: false, includePasswords: true) == .off)
        #expect(ClipboardSharing(share: true, includePasswords: false) == .shared)
        #expect(ClipboardSharing(share: true, includePasswords: true) == .withPasswords)
    }
}
