import Foundation
import Testing
@testable import PrismLibrary

/// Ported from `noteMarkdown.test.ts` and `noteAutosave.test.ts`.
@Suite struct NoteMarkdownTests {
    @Test func preservesALegacySeparateTitleOnceAndLeavesMarkdownSourceUntouched() {
        let note = LibraryEntry(id: "legacy", kind: .note, title: "Meeting", value: "- [x] Ship\n\n```ts\nrun();\n```")
        let document = NoteMarkdown.forEditing(note)
        #expect(document.value == "# Meeting\n\n\(note.value)")
        #expect(NoteMarkdown.forEditing(NoteMarkdown.forStorage(document, fallbackTitle: "New note")) == document)
        var edited = document
        edited.title = ""
        edited.value = document.value.replacingOccurrences(of: "Meeting", with: "Today")
        let renamed = NoteMarkdown.forStorage(edited, fallbackTitle: "New note")
        #expect(renamed.title == "Today")
        #expect(NoteMarkdown.forEditing(renamed).value == renamed.value)
    }

    @Test func derivesTheFirstNonemptyHeadingWithoutInsertingFallbackTitlesIntoClearedNotes() {
        #expect(NoteMarkdown.title("\n## 한국어 제목 ##\n본문") == "한국어 제목")
        #expect(NoteMarkdown.title("# " + String(repeating: "🚀", count: 80)) == String(repeating: "🚀", count: 75))
        for title in ["New note", "새 노트"] {
            #expect(NoteMarkdown.forEditing(LibraryEntry(id: "empty", kind: .note, title: title, value: "")).value == "")
        }
    }

    @Test func derivesABoundedTitleWithoutChangingTheBodyOrTruncatingAnExplicitTitle() {
        let note = LibraryEntry(id: "note", kind: .note, title: "", value: "")
        var withBody = note
        withBody.value = "\n메모 첫 줄\n{date}"
        let stored = NoteMarkdown.forStorage(withBody, fallbackTitle: "새 노트")
        #expect(stored.title == "메모 첫 줄")
        #expect(stored.value == "\n메모 첫 줄\n{date}")
        #expect(NoteMarkdown.forStorage(note, fallbackTitle: "새 노트").title == "새 노트")
        var rockets = note
        rockets.value = String(repeating: "🚀", count: 150)
        #expect(NoteMarkdown.forStorage(rockets, fallbackTitle: "새 노트").title == String(repeating: "🚀", count: 75))
        var explicit = note
        explicit.title = String(repeating: "a", count: 100)
        #expect(NoteMarkdown.forStorage(explicit, fallbackTitle: "새 노트").title.count == 100)
    }

    @Test func excerptSkipsTheTitleLine() {
        #expect(NoteMarkdown.excerpt("# Title\n\nFirst line\nSecond") == "First line Second")
        #expect(NoteMarkdown.excerpt("Only") == "")
    }

    @Test func markdownBlocksCoverHeadingsListsTasksTablesAndCode() {
        let blocks = MarkdownBlock.parse("# Title\n\n- item\n- [x] done\n1. first\n> quote\n\n| a | b |\n| - | - |\n| 1 | 2 |\n\n```swift\nlet x = 1\n```\ntext")
        #expect(blocks == [
            .heading(level: 1, text: "Title"),
            .listItem(indent: 0, marker: .bullet, text: "item"),
            .listItem(indent: 0, marker: .task(done: true), text: "done"),
            .listItem(indent: 0, marker: .number("1."), text: "first"),
            .quote("quote"),
            .table(header: ["a", "b"], rows: [["1", "2"]]),
            .code(language: "swift", text: "let x = 1"),
            .paragraph("text"),
        ])
    }

    @Test func inlineMarkdownDropsImagesAndNonWebLinks() {
        let attributed = MarkdownPreview.inline("![logo](https://x/y.png) [run](file:///etc) [web](https://example.com)")
        #expect(String(attributed.characters).contains("[logo]"))
        let links = attributed.runs.compactMap(\.link)
        #expect(links == [URL(string: "https://example.com")!])
    }
}

@MainActor
@Suite struct NoteAutosaveTests {
    let note = LibraryEntry(id: "note", kind: .note, title: "", value: "")

    /// A persist function whose writes finish only when the test says so.
    @MainActor
    final class Gate {
        var calls: [LibraryEntry] = []
        var continuations: [CheckedContinuation<Void, Error>] = []
        var failNext: Error?

        func persist(_ entry: LibraryEntry) async throws {
            calls.append(entry)
            try await withCheckedThrowingContinuation { continuations.append($0) }
        }

        func complete(_ index: Int, error: Error? = nil) {
            if let error { continuations[index].resume(throwing: error) } else { continuations[index].resume() }
        }
    }

    func settleTasks() async {
        for _ in 0..<20 { await Task.yield() }
    }

    @Test func coalescesPendingChangesAndNeverWritesAnOlderVersionAfterANewerOne() async {
        let gate = Gate()
        var statuses: [NoteAutosave.Status] = []
        let autosave = NoteAutosave(initial: note, persist: gate.persist, onStatus: { statuses.append($0) })
        var first = note; first.value = "first"
        autosave.update(first)
        await settleTasks()
        var middle = note; middle.value = "middle"
        var latest = note; latest.value = "latest"
        autosave.update(middle)
        autosave.update(latest)
        let leaving = autosave.flush()
        #expect(gate.calls.count == 1)
        gate.complete(0)
        await settleTasks()
        #expect(gate.calls.count == 2)
        #expect(gate.calls[1] == latest)
        gate.complete(1)
        #expect(await leaving.value)
        #expect(statuses.last == .saved)
    }

    @Test func keepsTheLatestEditForRetryAfterAnInFlightFailure() async {
        struct DiskFull: LocalizedError { var errorDescription: String? { "Disk full" } }
        let gate = Gate()
        var statuses: [NoteAutosave.Status] = []
        let autosave = NoteAutosave(initial: note, persist: gate.persist, onStatus: { statuses.append($0) })
        var first = note; first.value = "first"
        autosave.update(first)
        await settleTasks()
        var latest = note; latest.value = "latest"
        autosave.update(latest)
        let pending = autosave.flush()
        gate.complete(0, error: DiskFull())
        #expect(await pending.value == false)
        #expect(statuses.last == .failed("Disk full"))
        let retry = autosave.flush()
        await settleTasks()
        gate.complete(1)
        #expect(await retry.value)
        #expect(gate.calls.last == latest)
    }

    @Test func doesNotWriteUntouchedNotesAndPersistsClearingAnExistingNote() async {
        var calls: [LibraryEntry] = []
        let initial = LibraryEntry(id: "note", kind: .note, title: "Title", value: "Body")
        let autosave = NoteAutosave(initial: initial, persist: { calls.append($0) }, onStatus: { _ in })
        #expect(await autosave.flush().value)
        #expect(calls.isEmpty)
        autosave.update(note)
        #expect(await autosave.settle())
        #expect(calls == [note])
    }
}
