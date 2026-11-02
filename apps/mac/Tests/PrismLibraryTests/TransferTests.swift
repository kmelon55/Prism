import Foundation
import PrismKit
import Testing

@testable import PrismLibrary

@Test func transferMergesNotesWithoutChangingSnippetsAndReplacesOnlySelectedKind() throws {
  let store = try LibraryStore(database: .inMemory())
  let local = LibraryEntry(kind: .note, title: "Local", value: "keep")
  let snippet = LibraryEntry(kind: .snippet, title: "Snippet", value: "untouched")
  let incoming = LibraryEntry(kind: .note, title: "Remote", value: "new")
  try store.save(local)
  try store.save(snippet)
  let data = try TransferCodec.encode([TransferEntry(incoming)])
  try store.applyTransfer(data, kind: .note, replace: false)
  #expect(Set(try store.load().entries.map(\.id)) == Set([local.id, snippet.id, incoming.id]))
  try store.applyTransfer(data, kind: .note, replace: true)
  #expect(Set(try store.load().entries.map(\.id)) == Set([snippet.id, incoming.id]))
}
@Test func transferRejectsDuplicateKeywordsAtomically() throws {
  let store = try LibraryStore(database: .inMemory())
  let first = LibraryEntry(kind: .snippet, title: "A", value: "one", keyword: ";same")
  let second = LibraryEntry(kind: .snippet, title: "B", value: "two", keyword: ";same")
  try store.save(first)
  let before = try store.load()
  #expect(throws: (any Error).self) {
    try store.applyTransfer(
      TransferCodec.encode([TransferEntry(second)]), kind: .snippet, replace: false)
  }
  #expect(try store.load() == before)
}
@Test func transferDoesNotOverwriteAnotherKindWithSameID() throws {
  let store = try LibraryStore(database: .inMemory())
  let note = LibraryEntry(kind: .note, title: "Note", value: "keep")
  try store.save(note)
  let replacement = LibraryEntry(id: note.id, kind: .snippet, title: "Wrong", value: "wrong")
  #expect(throws: (any Error).self) {
    try store.applyTransfer(
      TransferCodec.encode([TransferEntry(replacement)]), kind: .snippet, replace: false)
  }
  #expect(try store.load().entries == [note])
}

@Test func transferPreservesLegacyIDsAndRejectsInvalidIDs() throws {
  let store = try LibraryStore(database: .inMemory())
  let legacy = LibraryEntry(id: "legacy-note", kind: .note, title: "Legacy", value: "keep")
  try store.applyTransfer(
    TransferCodec.encode([TransferEntry(legacy)]), kind: .note, replace: false)
  #expect(try store.load().entries == [legacy])
  let invalid = LibraryEntry(id: "", kind: .note, title: "Bad", value: "reject")
  #expect(throws: (any Error).self) {
    try store.applyTransfer(
      TransferCodec.encode([TransferEntry(invalid)]), kind: .note, replace: true)
  }
  #expect(try store.load().entries == [legacy])
}

@Test @MainActor func noteTransferWaitsForEditsAndRefreshesOpenDocument() async throws {
  let store = try LibraryStore(database: .inMemory())
  let note = LibraryEntry(kind: .note, title: "Original", value: "Original text")
  try store.save(note)
  let library = LibraryModel(store: store)
  let editor = NotesModel(library: library)
  await editor.openInitial(noteID: note.id)
  try editor.ensureTransferReady()
  editor.documentText = "Unsaved text"
  #expect(throws: (any Error).self) { try editor.ensureTransferReady() }
  #expect(await editor.settle())
  try editor.ensureTransferReady()
  let updated = LibraryEntry(id: note.id, kind: .note, title: "Remote", value: "Remote text")
  editor.refreshAfterTransfer([updated])
  #expect(editor.document == NoteMarkdown.forEditing(updated))
  editor.refreshAfterTransfer([])
  #expect(editor.document == nil)
}
