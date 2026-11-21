#if os(macOS)
    import GliffClipboard
    import GliffInput
    import GliffProtocol
    import Synchronization
    import Testing

    @testable import GliffSession

    /// The clipboard through a whole session against `fake-server serve clipboard-offer` (the
    /// remote's text, HTML and PNG fetched; `--hostile`, an oversized chunk aborted) and
    /// `clipboard-request` (the Mac's text served at once, in order and within the window).
    /// Files aren't shared.
    extension SessionIntegrationTests {
        /// Fetches each of `mimes` from the remote's first offer, then disconnects.
        private func fetchEach(_ mimes: [String], args: [String]) async throws -> (
            Outcome, [String: Result<[UInt8], TransferError>]
        ) {
            let fetched = Mutex<[String: Result<[UInt8], TransferError>]>([:])
            let started = Flag()
            let outcome = try await session(
                args, clipboard: ClipboardSetup(source: PatternSource(count: 0)),
                onStatus: { status, session in
                    guard case .clipboardOffer(let offer) = status, let bridge = session.clipboard,
                        started.raise()
                    else { return }
                    Task {
                        for mime in mimes {
                            let result: Result<[UInt8], TransferError>
                            do throws(TransferError) {
                                result = .success(
                                    try await bridge.fetch(
                                        mime, serial: offer.serial, progress: TransferProgress()))
                            } catch {
                                result = .failure(error)
                            }
                            fetched.withLock { $0[mime] = result }
                        }
                        await session.disconnect()
                    }
                })
            return (outcome, fetched.withLock { $0 })
        }

        @Test func fetchesTextHtmlAndPng() async throws {
            let mimes = [ClipboardMimes.text, ClipboardMimes.html, ClipboardMimes.png]
            let (outcome, fetched) = try await fetchEach(mimes, args: ["clipboard-offer"])
            #expect(outcome.serverFailure == nil)
            #expect(outcome.end == .disconnected)
            #expect(try fetched[ClipboardMimes.text]?.get() == Array("héllo".utf8))
            #expect(try fetched[ClipboardMimes.html]?.get() == Array("<b>hi</b>".utf8))
            #expect(try fetched[ClipboardMimes.png]?.get() == pattern(100))
        }

        /// A stray chunk first, then an HTML chunk over 256 KiB: the HTML fails (and is aborted,
        /// which the server checks), the text still comes.
        @Test func refusesAHostileOffer() async throws {
            let mimes = [ClipboardMimes.html, ClipboardMimes.text]
            let (outcome, fetched) = try await fetchEach(mimes, args: ["clipboard-offer", "--hostile"])
            #expect(outcome.serverFailure == nil)
            #expect(outcome.end == .disconnected)
            #expect(fetched[ClipboardMimes.html] == .failure(.invalid))
            #expect(try fetched[ClipboardMimes.text]?.get() == Array("héllo".utf8))
        }

        /// The offer, with no input: the server reads 1 500 000 pattern bytes at once, within the
        /// window, then offers its own clipboard, and the session disconnects.
        @Test func servesAtOnce() async throws {
            let offered = Flag()
            let outcome = try await session(
                ["clipboard-request"], clipboard: ClipboardSetup(source: PatternSource(count: 1_500_000)),
                onStatus: { status, session in
                    switch status {
                    case .streaming where offered.raise():
                        session.offerClipboard(
                            LocalClipboardOffer(mimeTypes: [ClipboardMimes.text], token: 1))
                    case .clipboardOffer:
                        await session.disconnect()
                    default: break
                    }
                })
            #expect(outcome.serverFailure == nil)
            #expect(outcome.end == .disconnected)
        }
    }

    /// Serves `count` pattern bytes for any type.
    private struct PatternSource: LocalClipboardSource {
        let count: Int

        func source(for mime: String, token: Int) async throws(TransferError) -> any ChunkSource {
            MemorySource(pattern(count))
        }
    }

    /// The test pattern: byte i is i % 251.
    private func pattern(_ count: Int) -> [UInt8] { (0..<count).map { UInt8($0 % 251) } }
#endif
