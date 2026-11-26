/// What to do with an item whose name is taken where it goes.
public enum ClashChoice: Sendable {
    /// Put it in place of the existing one (files only).
    case replace
    /// Give it Finder's next free name: "report 2.pdf".
    case keepBoth
    /// Stop the batch: items already copied stay.
    case stop
}

/// A person's answer to a clash, and whether it holds for the rest of the batch.
public struct ClashAnswer: Sendable {
    public var choice: ClashChoice
    public var applyToAll: Bool

    public init(_ choice: ClashChoice, applyToAll: Bool = false) {
        (self.choice, self.applyToAll) = (choice, applyToAll)
    }
}

/// How a batch settles a taken name.
public enum NameClashPolicy: Sendable {
    /// Never ask: Finder's " 2" (a drop, a drag out, Download).
    case keepBoth
    /// Ask with the shown name and whether Replace can be offered (the Files window's
    /// uploads): only a file over a file, on a server with `posix-rename`. Replace where it
    /// can't be offered keeps both. The question should end when its task is cancelled; the
    /// batch then stops whatever it answered.
    case ask(@Sendable (_ name: String, _ canReplace: Bool) async -> ClashAnswer)
}
