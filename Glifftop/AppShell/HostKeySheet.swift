import GliffTransport
import SwiftUI

/// A host key this Mac doesn't know, or ssh's other yes/no question about one: Allow or Deny.
/// Neither is the default, so Return does nothing; Escape is Deny.
struct HostKeySheet: View {
    let question: SignInQuestion
    let answer: (consuming SignInAnswer) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            switch question {
            case .hostKey(let key): unknownKey(key)
            case .confirm(_, let text):
                Text("ssh asks about \(question.hostShown)’s key")
                    .font(.title3)
                HostTextBox(text: text)
            default: EmptyView()
            }
            HStack {
                Spacer()
                Button("Deny", role: .cancel) { answer(.deny) }
                    .keyboardShortcut(.cancelAction)
                Button("Allow") { answer(.allow) }
            }
        }
        .padding(20)
        .frame(width: 460, alignment: .leading)
    }

    @ViewBuilder private func unknownKey(_ key: HostKeyQuestion) -> some View {
        Text("This Mac doesn’t know \(question.hostShown)’s key")
            .font(.title3)
        VStack(alignment: .leading, spacing: 4) {
            Text("\(SSHErrorClassifier.displayable(key.keyType)) key fingerprint")
                .foregroundStyle(.secondary)
            Text(SSHErrorClassifier.displayable(key.fingerprint))
                .font(.body.monospaced())
                .textSelection(.enabled)
        }
        ForEach(Array(key.details.enumerated()), id: \.offset) { _, line in
            Text(SSHErrorClassifier.displayable(line))
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        Text(
            "Check the fingerprint with the host’s owner, or with `ssh-keygen -lf` on the host. Allowing adds it to your known hosts."
        )
        .font(.callout)
        .fixedSize(horizontal: false, vertical: true)
    }
}
