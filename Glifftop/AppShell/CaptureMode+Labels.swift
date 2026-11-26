import GliffInput

/// The input modes as the app names and stores them: "Integrated" and "Capture", stored in
/// Settings as "integrated" and "capture".
extension CaptureMode {
    var label: String {
        switch self {
        case .integrated: "Integrated"
        case .confined: "Capture"
        }
    }

    /// Its value in `UserDefaults` (`AppSettings.inputModeKey`).
    var stored: String {
        switch self {
        case .integrated: "integrated"
        case .confined: "capture"
        }
    }

    /// A stored mode: anything but "capture" is Integrated.
    init(stored: String?) {
        self = stored == CaptureMode.confined.stored ? .confined : .integrated
    }
}
