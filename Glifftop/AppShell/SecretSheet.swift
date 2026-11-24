import GliffTransport
import SwiftUI

/// A passphrase, PIN, password or the host's own question: a secure field (shown as text on
/// request), Continue and Cancel. The host's words are set apart under "HOST asks:", so they
/// never read as Glifftop's. The typed text becomes a `SignInSecret` and the field is emptied
/// before the answer goes.
struct SecretSheet: View {
    let question: SignInQuestion
    let answer: (consuming SignInAnswer) -> Void
    @State private var text = ""
    @State private var showsText = false
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            heading
            Group {
                if showsText {
                    TextField("", text: $text)
                } else {
                    SecureField("", text: $text)
                }
            }
            .autocorrectionDisabled()
            .focused($focused)
            // The field changes with Show: the new one takes the focus.
            Toggle("Show", isOn: $showsText)
                .onChange(of: showsText) { focused = true }
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
        case .fromHost(let host, _, let hostText):
            Text("\(SSHErrorClassifier.displayable(host)) asks:")
                .font(.headline)
            HostTextBox(text: hostText)
        case .password(_, let account, let ssh):
            Text("Password for \(SSHErrorClassifier.displayable(account))")
                .font(.title3)
            // An expired password's questions (old, new, again) in ssh's own words.
            if !ssh.hasSuffix("'s password: ") {
                Text(SSHErrorClassifier.displayable(ssh))
                    .foregroundStyle(.secondary)
            }
        default:
            Text(question.keyPath.map { "Passphrase for key \($0)" } ?? passphraseText)
                .font(.title3)
                .fixedSize(horizontal: false, vertical: true)
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
