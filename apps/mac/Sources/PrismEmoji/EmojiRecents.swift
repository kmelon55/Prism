import Foundation

/// Up to 32 exact emoji strings, most recent first, in `emoji-recent-v1.json`. The Tauri picker kept the same
/// list in WebView storage (`prism:emoji:recent:v1`) with the same bounds.
struct EmojiRecents: Sendable {
    static let limit = 32
    static let maxFileBytes = 16 * 1024
    static let maxEmojiLength = 100

    let url: URL

    /// A missing, oversized or malformed file starts empty.
    func load() -> [String] {
        guard let size = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize, size <= Self.maxFileBytes,
              let data = try? Data(contentsOf: url),
              let values = try? JSONDecoder().decode([String].self, from: data) else { return [] }
        return Self.sanitize(values)
    }

    /// Moves `emoji` to the front, dropping entries that are not in the catalog. Returns the new list and
    /// whether it was saved; a failed write keeps the in-memory list.
    func remember(_ emoji: String, in current: [String], isKnown: (String) -> Bool) -> (recent: [String], saved: Bool) {
        let recent = Array(([emoji] + current.filter { $0 != emoji && isKnown($0) }).prefix(Self.limit))
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONEncoder().encode(recent).write(to: url, options: .atomic)
            return (recent, true)
        } catch {
            return (recent, false)
        }
    }

    static func sanitize(_ values: [String]) -> [String] {
        var seen = Set<String>()
        var result: [String] = []
        for value in values where value.utf16.count <= maxEmojiLength && !value.isEmpty {
            if seen.insert(value).inserted { result.append(value) }
            if result.count == limit { break }
        }
        return result
    }
}
