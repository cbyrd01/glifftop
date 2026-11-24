/// `SignInRouter`'s side of the connections: which waiter a question goes to.
extension HostConnections {
    enum Routing: Sendable {
        case asking(id: Int, task: Task<Void, Never>, slot: AnswerSlot)
        case deny
        /// No waiter may answer anything.
        case nobody
    }

    /// Puts `question` to the oldest waiter that may answer it (`SignInRouter`'s rules), in a
    /// task `stopWaiting` cancels.
    func startAsking(_ question: SignInQuestion, key: String, generation: Int) -> Routing {
        guard generation == self.generation, let host = hosts[key] else { return .nobody }
        let askers = host.waiters.filter { !$0.value.leaving.isSet }.sorted { $0.key < $1.key }.compactMap {
            id, waiter in waiter.asker.map { (id: id, fresh: waiter.fresh, asker: $0) }
        }
        guard !askers.isEmpty else { return .nobody }
        guard let chosen = askers.first(where: { !question.isAboutHostKey || $0.fresh }) else {
            hosts[key]?.verdict = .deniedKey
            return .deny
        }
        let slot = AnswerSlot()
        let task = Task { [asker = chosen.asker] in slot.put(await asker.ask(question)) }
        nextID += 1
        hosts[key]?.asking[nextID] = (chosen.id, task)
        return .asking(id: nextID, task: task, slot: slot)
    }

    /// Ends a question's record: whether its waiter still waits, so its answer counts.
    func finishAsking(_ id: Int, key: String) -> Bool {
        guard let asking = hosts[key]?.asking.removeValue(forKey: id),
            let waiter = hosts[key]?.waiters[asking.waiter]
        else { return false }
        return !waiter.leaving.isSet
    }

    /// Returns once a waiter with an asker comes, or after `openGrace`.
    func waitForAsker(key: String, generation: Int) async {
        guard generation == self.generation, hosts[key] != nil else { return }
        nextID += 1
        let id = nextID
        let timer = Task { [clock, openGrace] in
            try? await clock.sleep(for: openGrace)
            self.wakeAskerWait(key, id)
        }
        await withCheckedContinuation { continuation in
            self.assumeIsolated { $0.hosts[key]?.askerWaits[id] = continuation }
        }
        timer.cancel()
    }

    /// The router cancelled a question for want of anyone to ask.
    func cancelledForNobody(key: String, generation: Int) {
        guard generation == self.generation else { return }
        hosts[key]?.verdict = .cancelled
    }

    func wakeAskerWaits(_ key: String) {
        let waits = hosts[key]?.askerWaits.values.map { $0 } ?? []
        hosts[key]?.askerWaits = [:]
        for wait in waits { wait.resume() }
    }

    private func wakeAskerWait(_ key: String, _ id: Int) {
        hosts[key]?.askerWaits.removeValue(forKey: id)?.resume()
    }
}
