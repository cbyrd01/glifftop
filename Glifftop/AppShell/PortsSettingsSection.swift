import SwiftUI

/// Settings' "Forward new ports automatically", the same setting as the Ports popover's
/// checkbox (`AppPorts.automatic`).
struct PortsSettingsSection: View {
    @Bindable private var app = AppPorts.shared

    var body: some View {
        Toggle("Forward new ports automatically", isOn: $app.automatic)
        Text(
            "A port that starts listening on a host while its window is open is forwarded to this Mac. Database and cache ports are only offered."
        )
        .font(.callout)
        .foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)
    }
}
