import GliffTransport
import SwiftUI

/// Asks for the host and the screen, and starts the session. The last host is remembered; the
/// screen starts on Settings' choice, and the host's monitors appear only after Get Screens.
struct ConnectView: View {
    let model: SessionModel
    @AppStorage("lastTarget") private var target = ""
    /// Settings' choice: the picker follows it when it changes.
    @AppStorage(AppSettings.connectScreenKey) private var defaultScreen = "focused"
    @State private var screen = AppSettings.connectScreen
    /// The host Connect refused, and why: shown while the field holds that host (an edit hides
    /// it, undoing the edit shows it again), so committing composed text on Connect can't clear it.
    @State private var refused: (target: String, message: String)?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Connect to a Gliff host")
                .font(.title2)
            // A host, not a login: no "user" or "@" in the prompt and a URL's content type, so
            // AutoFill and password managers don't take it for a username field; no Writing
            // Tools or autocorrection either, which could hold the typing in a panel.
            TextField("Host", text: $target, prompt: Text("ssh host"))
                .textFieldStyle(.roundedBorder)
                .textContentType(.URL)
                .autocorrectionDisabled()
                .writingToolsBehavior(.disabled)
                .frame(minWidth: 280)
                .onChange(of: target) { model.screenList.forget(unless: target) }
            Text("host, user@host or ssh://user@host:port")
                .font(.callout)
                .foregroundStyle(.secondary)
            if let refused, refused.target == target {
                Text(refused.message)
                    .foregroundStyle(.red)
                    .font(.callout)
            }
            HStack {
                Picker("Screen", selection: $screen) {
                    Text(ScreenChoice.focused.label).tag(ScreenChoice.focused)
                    Text(ScreenChoice.virtual.label).tag(ScreenChoice.virtual)
                    if !model.screenList.screens.isEmpty {
                        Divider()
                        ForEach(model.screenList.screens, id: \.name) { listed in
                            Text(listed.label).tag(ScreenChoice.named(listed.name))
                        }
                    }
                }
                Button("Get Screens", action: getScreens)
                    .disabled(model.screenList.isListing)
                if model.screenList.isListing {
                    ProgressView()
                        .controlSize(.small)
                }
            }
            // A monitor no longer listed (the host was edited, or a new list lacks it) can't
            // stay chosen.
            .onChange(of: model.screenList.screens) { screen = usable(screen, host: target) }
            .onChange(of: defaultScreen) { screen = AppSettings.connectScreen }
            if let error = model.screenList.error {
                Text(error)
                    .foregroundStyle(.red)
                    .font(.callout)
            }
            HStack {
                Spacer()
                Button("Connect", action: connect)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
    }

    /// The host the field shows. Text it holds but its value may lack (still composing, or
    /// put there by AutoFill) is committed first; it's remembered as shown, and a list for
    /// another host is forgotten now, not after this action.
    private func shownTarget() -> String {
        let shown = TextComposition.commit() ?? target
        if target != shown { target = shown }
        model.screenList.forget(unless: shown)
        return shown
    }

    /// `choice`, unless it's a monitor `host`'s list doesn't have: then Settings' choice.
    private func usable(_ choice: ScreenChoice, host: String) -> ScreenChoice {
        model.screenList.allows(choice, host: host) ? choice : AppSettings.connectScreen
    }

    private func getScreens() {
        model.screenList.list(host: shownTarget())
    }

    private func connect() {
        // What the refused host is compared with.
        let shown = shownTarget()
        screen = usable(screen, host: shown)
        do {
            try model.connect(to: shown, screen: screen)
        } catch {
            refused = (shown, error.message)
        }
    }
}
