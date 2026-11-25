/// Waits up to 10 s of real time for `condition`, a bound only a broken test reaches.
public func eventually(_ condition: () async -> Bool) async -> Bool {
    for _ in 0..<1000 {
        if await condition() { return true }
        try? await Task.sleep(for: .milliseconds(10))
    }
    return await condition()
}
