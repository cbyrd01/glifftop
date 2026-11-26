/// Reads a run's channel, chunk by chunk (spec 4.4). Bytes before the start line are output (a
/// login banner); after it, the first trailer ends the run, and the newline the wrapper put
/// before it is dropped. A line with another token, or other words, is output. The first
/// `keptLimit` bytes of output are kept and the rest counted; `totalLimit` bytes in all end the
/// run as too large.
struct MacroOutput {
    enum End: Equatable {
        case exit(Int32)
        case timeout
        case tooLarge
    }

    static let keptLimit = 64 * 1024
    static let totalLimit = 4 * 1024 * 1024
    /// The longest trailer words: `exit` and a 32-bit status.
    private static let wordsLimit = 16

    private(set) var sawStart = false
    private(set) var end: End?
    private(set) var kept: [UInt8] = []
    private(set) var dropped = 0
    private var total = 0
    /// Bytes not yet known to be output: they may begin the start line or a trailer.
    private var pending: [UInt8] = []
    private let startLine: [UInt8]
    private let marker: [UInt8]

    init(token: MacroToken) {
        (startLine, marker) = (token.startLine, token.trailerMarker)
    }

    mutating func feed(_ chunk: [UInt8]) {
        guard end == nil else { return }
        total += chunk.count
        pending += chunk
        if !sawStart { findStart() }
        if sawStart { findTrailer() }
        if end == nil, total >= Self.totalLimit { end = .tooLarge }
    }

    /// The channel ended: whatever is pending is output.
    mutating func finish() {
        commit(pending.count)
    }

    private mutating func findStart() {
        if let at = pending.firstRange(of: startLine) {
            commit(at.lowerBound)
            pending.removeFirst(startLine.count)
            sawStart = true
        } else {
            commitAllBut(startLine.count - 1)
        }
    }

    /// Looks for the first marker followed by valid words. A marker whose words are still
    /// arriving stays pending; any other is output.
    private mutating func findTrailer() {
        var from = pending.startIndex
        while let at = pending[from...].firstRange(of: marker) {
            let words = pending[at.upperBound...].prefix(Self.wordsLimit + 1)
            if let newline = words.firstIndex(of: UInt8(ascii: "\n")) {
                if let found = Self.parse(String(decoding: words[..<newline], as: UTF8.self)) {
                    commit(at.lowerBound)
                    pending = []
                    end = found
                    return
                }
            } else if words.count <= Self.wordsLimit {
                commit(at.lowerBound)
                return
            }
            from = at.lowerBound + 1
        }
        commitAllBut(marker.count - 1)
    }

    private static func parse(_ words: String) -> End? {
        if words == "timeout" { return .timeout }
        guard words.hasPrefix("exit "), let status = Int32(words.dropFirst(5)) else { return nil }
        return .exit(status)
    }

    /// Commits all pending bytes but the last `count`, which may begin a match.
    private mutating func commitAllBut(_ count: Int) {
        commit(pending.count - count)
    }

    /// Moves the first `count` pending bytes to the output, kept up to the cap.
    private mutating func commit(_ count: Int) {
        guard count > 0 else { return }
        let room = max(0, Self.keptLimit - kept.count)
        kept += pending.prefix(min(room, count))
        dropped += max(0, count - room)
        pending.removeFirst(count)
    }
}
