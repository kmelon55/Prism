import Foundation

/// Note titles and excerpts, ported from `noteMarkdown.ts` and `noteAutosave.ts`.
enum NoteMarkdown {
    static let titleLimit = 75

    private static func firstNonemptyLine(_ value: String) -> String {
        value.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline)
            .first { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
            .map { $0.trimmingCharacters(in: .whitespaces) } ?? ""
    }

    /// The first nonempty line without Markdown heading markers, at most 75 code points.
    static func title(_ value: String) -> String {
        var line = firstNonemptyLine(value)
        if let range = line.range(of: #"^#{1,6}\s+"#, options: .regularExpression) { line.removeSubrange(range) }
        if let range = line.range(of: #"\s+#+$"#, options: .regularExpression) { line.removeSubrange(range) }
        return String(String.UnicodeScalarView(line.unicodeScalars.prefix(titleLimit)))
    }

    /// Lines after the title, joined, for the notes list.
    static func excerpt(_ value: String) -> String {
        let lines = value.prefix(2000).split(whereSeparator: \.isNewline).filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        return String(lines.dropFirst().joined(separator: " ").prefix(120))
    }

    /// Keeps a title written in the old separate title field as a Markdown heading.
    static func forEditing(_ entry: LibraryEntry) -> LibraryEntry {
        guard entry.kind == .note else { return entry }
        let title = entry.title.trimmingCharacters(in: .whitespacesAndNewlines)
        let hasSeparateTitle = !title.isEmpty && title != Self.title(entry.value) && title != firstNonemptyLine(entry.value)
            && !(entry.value.isEmpty && ["New note", "새 노트", "New Note"].contains(title))
        var result = entry
        if hasSeparateTitle { result.value = "# \(title)\n\n\(entry.value)" }
        return result
    }

    /// Fills the stored title from the first line without rewriting the body or shortening an explicit title.
    static func forStorage(_ note: LibraryEntry, fallbackTitle: String) -> LibraryEntry {
        var result = note
        let trimmed = note.title.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            let derived = title(note.value)
            let chosen = derived.isEmpty ? fallbackTitle : derived
            result.title = String(String.UnicodeScalarView(chosen.unicodeScalars.prefix(titleLimit)))
        } else {
            result.title = trimmed
        }
        return result
    }
}
