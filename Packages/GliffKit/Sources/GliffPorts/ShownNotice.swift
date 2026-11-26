/// The one notice a window shows, and whether it just came: the status bar shows `notice`,
/// the picture's capsule only a new one.
public struct ShownNotice: Equatable, Sendable {
    public let notice: PortNotice?
    public let isNew: Bool

    public init(notice: PortNotice?, isNew: Bool) { (self.notice, self.isNew) = (notice, isNew) }
}

extension PortsSnapshot {
    /// What a window shows after `previous` (nil for its first snapshot, where nothing is new),
    /// where it showed `shown`:
    /// - the last notice that is new: an offer naming a port no earlier offer named, or a
    ///   forward's notice not there before;
    /// - else `shown`, while it lasts;
    /// - else the last notice.
    public func shownNotice(since previous: PortsSnapshot?, shown: PortNotice?) -> ShownNotice {
        if let previous {
            let offered = Set(previous.notices.flatMap(\.offeredPorts))
            let new = notices.last { notice in
                let ports = notice.offeredPorts
                return ports.isEmpty ? !previous.notices.contains(notice) : !offered.isSuperset(of: ports)
            }
            if let new { return ShownNotice(notice: new, isNew: true) }
        }
        if let shown, notices.contains(shown) { return ShownNotice(notice: shown, isNew: false) }
        return ShownNotice(notice: notices.last, isNew: false)
    }
}

extension PortNotice {
    /// The ports an offer names; none for a forward's notice.
    fileprivate var offeredPorts: [Int] {
        switch self {
        case .listening(let offer): [offer.port]
        case .several(let ports): ports
        case .forwarded, .moved: []
        }
    }
}
