import GliffTransport
import SwiftUI

/// A passphrase, PIN, password or the host's own question, laid out as the Mac's own sign-in
/// sheets are: a bold heading saying what the secret is for ("Sign in to HOST", "Unlock the
/// key …") without naming it, a password's user on a row of its own, a labelled secure field
/// with a "Show password" checkbox under it, then Cancel and Continue. The host's words are
/// set apart under "HOST asks:", so they never read as Glifftop's. The typed text becomes a
/// `SignInSecret` and the field is emptied before the answer goes.
struct SecretSheet: View {
    let question: SignInQuestion
    let answer: (consuming SignInAnswer) -> Void
    @State private var text = ""
    @State private var showsText = false
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            heading
            Form {
                // The user ssh signs in as, to see which password it needs; a different one is
                // a new connection (Cancel, then Edit Machine…).
                if let user = question.user {
                    LabeledContent("User", value: user)
                        .textSelection(.enabled)
                }
                Group {
                    if showsText {
                        TextField(secretName.label, text: $text)
                    } else {
                        SecureField(secretName.label, text: $text)
                    }
                }
                .autocorrectionDisabled()
                // A password manager's AutoFill offers its passwords here.
                .textContentType(isPassword ? .password : nil)
                .focused($focused)
                // The field changes with the checkbox: the new one takes the focus.
                Toggle(secretName.show, isOn: $showsText)
                    .onChange(of: showsText) { focused = true }
            }
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { cancel() }
                    .keyboardShortcut(.cancelAction)
                Button("Continue", action: send)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 460, alignment: .leading)
        // After the sheet is shown: focus set while it is still opening may not take.
        .task { focused = true }
        .onDisappear { text = "" }
    }

    @ViewBuilder private var heading: some View {
        switch question {
        case .fromHost(_, _, let hostText):
            Text("\(question.hostShown) asks:")
                .font(.headline)
            HostTextBox(text: hostText)
        case .password(_, _, let ssh):
            Text("Sign in to \(question.hostShown)")
                .font(.headline)
            // An expired password's questions (old, new, again) in ssh's own words.
            if !ssh.hasSuffix("'s password: ") {
                Text(SSHErrorClassifier.displayable(ssh))
                    .foregroundStyle(.secondary)
            }
        default:
            Text(question.keyPath.map { "Unlock the key \($0)" } ?? passphraseText)
                .font(.headline)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// A password or a key's passphrase, as password managers keep them; not a security key's
    /// PIN or the host's own question (often a one-time code).
    private var isPassword: Bool {
        switch question {
        case .password: true
        case .fromHost: false
        default: question.keyPath != nil
        }
    }

    /// What is typed: the field's label and the checkbox's words.
    private var secretName: (label: String, show: String) {
        switch question {
        case .password: ("Password", "Show password")
        case .fromHost: ("Answer", "Show answer")
        default: question.keyPath == nil ? ("PIN", "Show PIN") : ("Passphrase", "Show passphrase")
        }
    }

    /// A security key's PIN, in ssh's own words.
    private var passphraseText: String {
        guard case .passphrase(_, let ssh) = question else { return "" }
        return SSHErrorClassifier.displayable(ssh)
    }

    private func send() {
        let secret = SignInSecret(copying: text)
        text = ""
        answer(.secret(secret))
    }

    private func cancel() {
        text = ""
        answer(.cancel)
    }
}
