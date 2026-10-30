import Foundation

/// `Dictation Recovery` in the app data folder. Independent of the clipboard and free of credentials.
/// Failed recordings stay until the user removes them; text is kept after transcription.
struct DictationRecoveryStore: Sendable {
    static let folderName = "Dictation Recovery"
    let directory: URL

    func prepare() throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
    }

    /// Copies the recording into a new timestamped entry before transcription starts.
    func preserve(_ audio: URL) throws -> URL {
        try prepare()
        let stamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-")
        let entry = directory.appendingPathComponent("\(stamp)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: entry, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        let saved = entry.appendingPathComponent("recording.wav")
        try FileManager.default.copyItem(at: audio, to: saved)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: saved.path)
        return entry
    }

    func save(_ text: String, named name: String, in entry: URL) throws {
        precondition(["original.txt", "result.txt"].contains(name))
        let file = entry.appendingPathComponent(name)
        try Data(text.utf8).write(to: file, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
    }

    /// Removes the audio only after both text checkpoints are saved.
    func finish(_ entry: URL) throws {
        let audio = entry.appendingPathComponent("recording.wav")
        if FileManager.default.fileExists(atPath: audio.path) { try FileManager.default.removeItem(at: audio) }
    }

    func latest() -> (original: String, result: String)? {
        let entries = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.creationDateKey],
                                                                    options: [.skipsHiddenFiles])) ?? []
        let sorted = entries.sorted {
            let left = (try? $0.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? .distantPast
            let right = (try? $1.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? .distantPast
            return left > right
        }
        for entry in sorted {
            guard let original = try? String(contentsOf: entry.appendingPathComponent("original.txt"), encoding: .utf8),
                  !original.isEmpty else { continue }
            let result = (try? String(contentsOf: entry.appendingPathComponent("result.txt"), encoding: .utf8)) ?? original
            return (original, result)
        }
        return nil
    }
}
