import Testing

@testable import GliffTransport

struct SignInSecretTests {
    @Test func aSecretGivesBackItsBytes() {
        let secret = SignInSecret(copying: "pässword")
        #expect(secret.count == Array("pässword".utf8).count)
        #expect(secret.withBytes { Array($0) } == Array("pässword".utf8))
    }

    @Test func aSecretCanBeMadeFromBytes() {
        let secret = SignInSecret(bytes: [1, 2, 3])
        #expect(secret.withBytes { Array($0) } == [1, 2, 3])
    }

    @Test func anEmptySecretHasNoBytes() {
        let secret = SignInSecret(copying: "")
        #expect(secret.count == 0)
        #expect(secret.withBytes { $0.isEmpty })
    }

    @Test func anAnswerCarriesItsSecret() {
        let answer = SignInAnswer.secret(SignInSecret(copying: "pw"))
        switch consume answer {
        case .secret(let secret): #expect(secret.withBytes { Array($0) } == Array("pw".utf8))
        default: Issue.record("not a secret")
        }
    }

    @Test func aQuestionNamesItsHost() {
        let key = HostKeyQuestion(host: "omarchy", keyType: "ED25519", fingerprint: "SHA256:abc", details: [])
        #expect(SignInQuestion.hostKey(key).host == "omarchy")
        #expect(SignInQuestion.password(host: "jump", account: "person@jump", text: "").host == "jump")
        #expect(
            SignInQuestion.fromHost(host: "omarchy", prefix: "(person@omarchy) ", text: "Code: ").host
                == "omarchy")
    }
}
