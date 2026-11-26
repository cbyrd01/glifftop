#if os(macOS)
    import Darwin
    import Foundation
    import GliffTestSupport
    import GliffTransport
    import os

    @testable import GliffMacros

    /// One run of the wrapper on a `LocalChannel`, its output kept as it arrives.
    final class WrapperRun: Sendable {
        let channel: LocalChannel
        let token: MacroToken
        private let state = OSAllocatedUnfairLock(
            initialState: (output: [UInt8](), end: TransportError??.none))

        init(channel: LocalChannel, token: MacroToken) {
            (self.channel, self.token) = (channel, token)
            Task { [state] in
                do {
                    for try await chunk in channel.incoming { state.withLock { $0.output += chunk } }
                    state.withLock { $0.end = .some(nil) }
                } catch {
                    state.withLock {
                        $0.end = error as? TransportError ?? .launchFailed("not a TransportError")
                    }
                }
            }
        }

        var output: String { String(decoding: state.withLock { $0.output }, as: UTF8.self) }
        var startLine: String { String(decoding: token.startLine, as: UTF8.self) }
        var trailerMarker: String { String(decoding: token.trailerMarker, as: UTF8.self) }

        /// What the script printed: the output after the start line and before the trailer's
        /// added newline, once both have arrived.
        var body: String? {
            let output = output
            guard output.hasPrefix(startLine), let trailer = output.range(of: trailerMarker) else {
                return nil
            }
            return String(output[..<trailer.lowerBound].dropFirst(startLine.count))
        }

        /// The first trailer's words, `exit N` or `timeout`, once it arrives within `limit`.
        func trailer(within limit: Duration) async -> String? {
            let marker = trailerMarker
            return await value(within: limit) {
                let output = output
                guard let start = output.range(of: marker)?.upperBound,
                    let end = output[start...].firstIndex(of: "\n")
                else { return nil }
                return String(output[start..<end])
            }
        }

        /// How `incoming` ended, once it has within `limit`: nil when it finished normally.
        func end(within limit: Duration) async -> TransportError?? {
            await value(within: limit) { state.withLock { $0.end } }
        }
    }

    /// The pid a script wrote to `file`, once it has within 5 s.
    func writtenPid(_ file: URL) async -> pid_t? {
        await value(within: .seconds(5)) {
            let text = (try? String(contentsOf: file, encoding: .utf8)) ?? ""
            return pid_t(text.trimmingCharacters(in: .whitespacesAndNewlines))
        }
    }
#endif
