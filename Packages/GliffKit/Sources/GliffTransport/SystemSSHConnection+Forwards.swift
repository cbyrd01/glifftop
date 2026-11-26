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

        /// One request, read by `classify`. Any failure is the connection lost when the master
        /// is gone or exits within a second, whatever ssh said, and only then; so a request
        /// that really failed takes that second longer to say so.
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
            guard error != .localPortInUse else { throw error }
            if await masterEnds(within: .seconds(1)) { throw .connectionLost }
            // ssh named the control socket, yet the master lives: this request failed.
            throw error == .connectionLost ? .failed : error
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
    }
#endif
