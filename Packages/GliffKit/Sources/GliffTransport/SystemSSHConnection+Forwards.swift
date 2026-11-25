extension ConfiguredForwards {
    /// The probe's forwards: each applied `LocalForward`, once (the first of those that differ
    /// only in their bind, which isn't applied), and every line not applied.
    init(config: SSHResolvedConfig) {
        var seen = Set<PortForward>()
        let local = config.localForwards.compactMap(\.configured).filter { seen.insert($0.forward).inserted }
        self.init(local: local, notApplied: config.notAppliedLines)
    }
}

#if os(macOS)
    import Foundation
    import os

    /// Forwards on the master: each an `-O forward` or `-O cancel` with an `SSHForwardSpec`,
    /// one at a time through `requests`, each within 5 s. ssh's answer is read by
    /// `SSHForwardClassifier` and never logged.
    extension SystemSSHConnection {
        public func forward(_ forward: PortForward, on loopback: Loopback) async throws(ForwardError) {
            try await ask(
                command.forward(SSHForwardSpec.make(forward, on: loopback)), SSHForwardClassifier.forward)
        }

        public func cancel(_ forward: PortForward, on loopback: Loopback) async throws(ForwardError) {
            try await ask(
                command.cancel(SSHForwardSpec.make(forward, on: loopback)), SSHForwardClassifier.cancel)
        }

        public var configuredForwards: ConfiguredForwards { get async { configured } }

        /// One request, read by `classify`. A failure or timeout is the connection lost when the
        /// master is gone or exits within a second, whatever ssh said; so a request that really
        /// failed takes that second longer to say so.
        private func ask(
            _ arguments: [String], _ classify: (Int32, String) -> Result<Void, ForwardError>
        ) async throws(ForwardError) {
            let error: ForwardError
            switch await askMaster(arguments) {
            case nil: throw .connectionLost
            case .success(let exit):
                guard case .failure(let classified) = classify(exit.status, exit.stderr) else { return }
                error = classified
            case .failure(.timedOut): error = .timedOut
            case .failure: error = .failed
            }
            if error == .failed || error == .timedOut, await masterEnds(within: .seconds(1)) {
                throw .connectionLost
            }
            throw error
        }

        /// The master's answer to one control request, in turn; nil once the connection ended.
        private func askMaster(_ arguments: [String]) async -> Result<
            ProcessOutput.Exit, ProcessOutput.Failure
        >? {
            await requests.run { [self] in
                if masterGone { return nil }
                return await ProcessOutput.exit(
                    executable: executable, arguments: arguments, timeout: .seconds(5))
            }
        }

        /// Adds `config`'s local forwards in a task of their own.
        func addForwardsInBackground(probed: Bool) {
            guard probed else {
                Self.log.info("config forwards not read: no ssh -G")
                return
            }
            guard configured != .none else { return }
            Task { await addForwards(configured.local, notApplied: configured.notApplied.count) }
        }

        /// Forwards each of `forwards` on 127.0.0.1 until the master ends, as `forward` does (so
        /// a later cancel matches it); returns how many it added.
        @discardableResult
        func addForwards(_ forwards: [ConfiguredForward], notApplied: Int = 0) async -> Int {
            var applied = 0
            for each in forwards where !masterGone {
                if (try? await forward(each.forward, on: .ipv4)) != nil { applied += 1 }
            }
            Self.log.info(
                "config forwards: \(applied) applied, \(forwards.count - applied) skipped, \(notApplied) not applied"
            )
            return applied
        }
    }
#endif
