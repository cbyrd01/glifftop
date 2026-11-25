import GliffTransport
import Observation
import SwiftUI

/// The window's sign-in questions: its sessions, reconnects and Get Screens ask through `queue`,
/// and its sheet shows `current`, one question at a time.
@Observable final class SignInPrompter {
    /// The asker the window's connections are given.
    @ObservationIgnored let queue = SignInQueue()
    /// The question the sheet shows.
    private(set) var current: SignInQueue.Pending?

    init() {
        queue.changed = { [weak self] in self?.current = self?.queue.current }
    }

    /// Answers question `id`, if it is still the one shown.
    func answer(_ answer: consuming SignInAnswer, for id: Int) { queue.answer(answer, for: id) }
}

extension View {
    /// The window's sign-in question as a sheet, from the view whose sheet is frontmost
    /// (`shown`): the root's, or the machine sheet's over it. Only an answer, or the question
    /// ending, dismisses it.
    func signInSheet(_ prompter: SignInPrompter, shown: Bool = true) -> some View {
        sheet(item: Binding(get: { shown ? prompter.current : nil }, set: { _ in })) { pending in
            SignInSheet(pending: pending, prompter: prompter)
                .id(pending.id)
                .interactiveDismissDisabled()
        }
    }
}

/// The sheet for a question: Allow or Deny about a host key, a notice to wait on, or a secret.
private struct SignInSheet: View {
    let pending: SignInQueue.Pending
    let prompter: SignInPrompter

    var body: some View {
        let answer = { (answer: consuming SignInAnswer) in prompter.answer(answer, for: pending.id) }
        switch pending.question {
        case .hostKey, .confirm: HostKeySheet(question: pending.question, answer: answer)
        case .notice(_, let text): NoticeSheet(host: pending.question.hostShown, text: text)
        case .passphrase, .password, .fromHost: SecretSheet(question: pending.question, answer: answer)
        }
    }
}

/// Text ssh or the host wrote, as `SignInQuestion.shownHostText` cleans it: set apart, selectable,
/// and scrolling past 200 points, so a long one never pushes a sheet's buttons off the screen.
struct HostTextBox: View {
    let text: String

    var body: some View {
        ScrollView {
            Text(SignInQuestion.shownHostText(text))
                .font(.body.monospaced())
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(8)
        }
        .frame(maxHeight: 200)
        .fixedSize(horizontal: false, vertical: true)
        .background(.quaternary, in: .rect(cornerRadius: 6))
    }
}

/// Something ssh shows until it is done (a security key's touch): nothing to answer.
private struct NoticeSheet: View {
    /// The host as `SignInQuestion.hostShown` names it.
    let host: String
    let text: String

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Signing in to \(host)")
                .font(.headline)
            HStack(alignment: .top, spacing: 12) {
                ProgressView()
                    .controlSize(.small)
                HostTextBox(text: text)
            }
        }
        .padding(20)
        .frame(width: 420, alignment: .leading)
    }
}
