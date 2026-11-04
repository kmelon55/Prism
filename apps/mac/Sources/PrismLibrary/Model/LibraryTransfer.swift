import Foundation
import PrismKit

struct TransferEntry: Codable {
  let id: String
  let title: String
  let value: String
  let keyword: String?
  init(_ entry: LibraryEntry) {
    id = entry.id
    title = entry.title
    value = entry.value
    keyword = entry.keyword
  }
  func entry(_ kind: LibraryEntry.Kind) -> LibraryEntry {
    LibraryEntry(id: id, kind: kind, title: title, value: value, keyword: keyword)
  }
}
extension LibraryStore {
  @MainActor func registerTransfers(
    ensureReady: @escaping () throws -> Void, didApply: @escaping ([LibraryEntry]) -> Void
  ) {
    for (kind, id, title) in [
      (LibraryEntry.Kind.note, "notes", "Notes"), (.snippet, "snippets", "Snippets"),
      (.link, "links", "Quicklinks"),
    ] {
      SyncTransfers.register(
        SyncTransfer(
          id: id, title: String(localized: String.LocalizationValue(title), bundle: .module.prismLocalized),
          read: {
            try ensureReady()
            return try TransferCodec.encode(
              self.load().entries.filter { $0.kind == kind }.sorted { $0.id < $1.id }.map(
                TransferEntry.init))
          }, validate: { data in _ = try Self.decodeTransfer(data, kind: kind) },
          apply: { data, replace in
            try ensureReady()
            try self.applyTransfer(data, kind: kind, replace: replace)
            didApply(try self.load().entries)
          }))
    }
  }
  static func decodeTransfer(_ data: Data, kind: LibraryEntry.Kind) throws -> [LibraryEntry] {
    let raw = try JSONDecoder().decode([TransferEntry].self, from: data)
    guard raw.count <= LibraryLimits.maxEntries, Set(raw.map(\.id)).count == raw.count else {
      throw TransferError(String(localized: "There are duplicate or too many items.", bundle: .module.prismLocalized))
    }
    let entries = raw.map { $0.entry(kind) }
    for entry in entries {
      try LibraryValidation.validate(entry)
    }
    return entries
  }
}
