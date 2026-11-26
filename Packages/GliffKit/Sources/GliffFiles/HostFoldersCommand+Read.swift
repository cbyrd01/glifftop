import GliffTransport

extension HostFoldersCommand {
    /// The folders the command names over `command`, else where sftp-server starts on `session`
    /// as home and Downloads; nil when neither answers.
    static func read(over command: any Transport, on session: SFTPSession) async -> HostFolders? {
        if let output = await output(of: command), let folders = parse(output) { return folders }
        guard let start = try? await session.realpath(Array(".".utf8)), let home = RemotePath(absolute: start)
        else { return nil }
        return HostFolders(home: home, downloads: home)
    }

    /// The command's output to its end, read past `maxOutput` no further; nil when the channel
    /// fails or the output hasn't ended within `limit`.
    static func output(of command: any Transport, limit: Duration = .seconds(15)) async -> [UInt8]? {
        guard let connection = try? await command.connect() else { return nil }
        let output = await withTaskGroup(of: [UInt8]?.self) { group in
            group.addTask {
                var bytes: [UInt8] = []
                do {
                    for try await chunk in connection.incoming {
                        bytes += chunk
                        if bytes.count > maxOutput { break }
                    }
                } catch {
                    return nil
                }
                return Task.isCancelled ? nil : bytes
            }
            group.addTask {
                try? await Task.sleep(for: limit)
                return nil
            }
            let first = await group.next() ?? nil
            group.cancelAll()
            return first
        }
        await connection.close()
        return output
    }
}
