import GliffAskpass
import Testing

@testable import GliffTransport

struct AskpassPromptTests {
    static let hostKey =
        "The authenticity of host 'omarchy (2001:db8::1)' can't be established.\n"
        + "ED25519 key fingerprint is: SHA256:ASFf47m3ZeIPySUT2MoJMWo0cEUXbpBbhcPi49mvyF8\n"
        + "This key is not known by any other names.\n"
        + "Are you sure you want to continue connecting (yes/no/[fingerprint])? "

    @Test func anUnknownHostKey() {
        #expect(
            AskpassPrompt.classify(Self.hostKey, kind: .ask, destination: "omarchy", names: [])
                == .hostKey(
                    HostKeyQuestion(
                        host: "omarchy", keyType: "ED25519",
                        fingerprint: "SHA256:ASFf47m3ZeIPySUT2MoJMWo0cEUXbpBbhcPi49mvyF8",
                        details: ["This key is not known by any other names."])))
    }

    @Test func aJumpHostsKeyNamesTheJumpHost() {
        let text = Self.hostKey.replacing("'omarchy (2001:db8::1)'", with: "'jump.example (192.0.2.1)'")
        guard
            case .hostKey(let key) = AskpassPrompt.classify(
                text, kind: .ask, destination: "omarchy", names: [])
        else {
            Issue.record("not a host key")
            return
        }
        #expect(key.host == "jump.example")
    }

    @Test func aConfirmation() {
        let text =
            "Warning: the ED25519 host key for 'omarchy' differs from the key for the IP address '192.0.2.1'\n"
            + "Are you sure you want to continue connecting (yes/no)? "
        #expect(
            AskpassPrompt.classify(text, kind: .ask, destination: "omarchy", names: [])
                == .confirm(host: "omarchy", text: text))
        let plain = "Are you sure you want to continue connecting (yes/no)? "
        #expect(
            AskpassPrompt.classify(plain, kind: .ask, destination: "omarchy", names: [])
                == .confirm(host: "omarchy", text: plain))
    }

    @Test func aPassphrase() {
        let text = "Enter passphrase for key '/Users/person/.ssh/id_ed25519': "
        #expect(
            AskpassPrompt.classify(text, kind: .ask, destination: "omarchy", names: [])
                == .passphrase(host: "omarchy", text: text))
        let pin = "Enter PIN for ED25519-SK key /Users/person/.ssh/id_ed25519_sk: "
        #expect(
            AskpassPrompt.classify(pin, kind: .ask, destination: "omarchy", names: [])
                == .passphrase(host: "omarchy", text: pin))
    }

    @Test func aPassword() {
        let text = "person@omarchy's password: "
        #expect(
            AskpassPrompt.classify(text, kind: .ask, destination: "omarchy", names: [])
                == .password(host: "omarchy", account: "person@omarchy", text: text))
    }

    @Test func aJumpHostsPassword() {
        let text = "person@jump.example's password: "
        #expect(
            AskpassPrompt.classify(text, kind: .ask, destination: "omarchy", names: [])
                == .password(host: "jump.example", account: "person@jump.example", text: text))
    }

    @Test(arguments: [
        "Enter person@omarchy's old password: ", "Enter person@omarchy's new password: ",
        "Retype person@omarchy's new password: ",
    ])
    func anExpiredPassword(_ text: String) {
        #expect(
            AskpassPrompt.classify(text, kind: .ask, destination: "omarchy", names: [])
                == .password(host: "omarchy", account: "person@omarchy", text: text))
    }

    @Test func keyboardInteractive() {
        #expect(
            AskpassPrompt.classify(
                "(person@omarchy) Verification code: ", kind: .ask, destination: "omarchy", names: [])
                == .fromHost(host: "omarchy", prefix: "(person@omarchy) ", text: "Verification code: "))
    }

    @Test(arguments: [
        "(person@omarchy) Enter passphrase for key '/Users/person/.ssh/id_ed25519': ",
        "(person@omarchy) person@omarchy's password: ",
        "(person@omarchy) \n" + hostKey,
        "(person@omarchy) Welcome\ndebug1: Next authentication method: publickey\nPassword: ",
    ])
    func hostTextImitatingSSHIsFromHost(_ text: String) {
        guard
            case .fromHost(let host, let prefix, _) = AskpassPrompt.classify(
                text, kind: .ask, destination: "x", names: [])
        else {
            Issue.record("not from the host")
            return
        }
        #expect(host == "omarchy" && prefix == "(person@omarchy) ")
    }

    /// Swift compares whole characters: a combining mark at the host's first byte must not hide
    /// ssh's ") " and pull the host's words into the prefix.
    @Test func aCombiningMarkCantMoveTheHostsTextIntoSSHsPrefix() {
        let text = "(person@omarchy) \u{301}evil@bank.example) Password: "
        #expect(
            AskpassPrompt.classify(text, kind: .ask, destination: "omarchy", names: [])
                == .fromHost(
                    host: "omarchy", prefix: "(person@omarchy) ", text: "\u{301}evil@bank.example) Password: "
                ))
    }

    /// ssh writes the HostName (and `[name]:port` off port 22): a question about the destination
    /// names it as typed.
    static func asking(about name: String) -> String {
        "The authenticity of host '\(name)' can't be established.\nED25519 key fingerprint is: SHA256:abc\n"
            + "Are you sure you want to continue connecting (yes/no/[fingerprint])? "
    }

    @Test(
        arguments: [
            asking(about: "192.0.2.5 (192.0.2.5)"), asking(about: "[192.0.2.5]:2222 ([192.0.2.5]:2222)"),
            asking(about: "Box.Alias (192.0.2.5)"), "person@192.0.2.5's password: ",
            "(person@192.0.2.5) Code: ",
        ] as [String])
    func theDestinationsResolvedNameIsShownAsTyped(_ text: String) {
        let question = AskpassPrompt.classify(
            text, kind: .ask, destination: "omarchy", names: ["192.0.2.5", "box.alias"])
        #expect(question?.host == "omarchy")
    }

    @Test func aUserNameWithASpace() {
        let text = "John Smith@winhost's password: "
        #expect(
            AskpassPrompt.classify(text, kind: .ask, destination: "winhost", names: [])
                == .password(host: "winhost", account: "John Smith@winhost", text: text))
    }

    @Test func aNotice() {
        let text = "Confirm user presence for key ED25519-SK SHA256:abc"
        #expect(
            AskpassPrompt.classify(text, kind: .notice, destination: "omarchy", names: [])
                == .notice(host: "omarchy", text: text))
    }

    @Test(arguments: [
        "Something else: ", "",
        hostKey.replacing(
            "ED25519 key fingerprint is: SHA256:ASFf47m3ZeIPySUT2MoJMWo0cEUXbpBbhcPi49mvyF8\n", with: ""),
        "'s password: ", "@'s password: ", "(no closing paren",
        "person@omar chy's password: ", "line\nperson@omarchy's password: ",
    ])
    func unknownTextIsNil(_ text: String) {
        #expect(AskpassPrompt.classify(text, kind: .ask, destination: "omarchy", names: []) == nil)
    }
}
