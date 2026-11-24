import SwiftUI

extension FocusedValues {
    /// The key window's model: what the menu bar's commands act on, nil (and the commands
    /// disabled) without one.
    @Entry var session: SessionModel?
}
