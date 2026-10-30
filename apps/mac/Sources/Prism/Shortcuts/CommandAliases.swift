import Foundation
import Observation
import PrismKit

/// One alias per command, such as "cb" for clipboard history, in `command-aliases-v1.json`. Backup restore and
/// Raycast import write the same file. An exact alias match ranks above a title match.
@MainActor
@Observable
final class CommandAliases {
    private struct File: Codable {
        var version = 1
        var aliases: [String: String]
    }

    private(set) var aliases: [String: String] = [:]
    /// Set when the file exists but cannot be read; it is then never overwritten.
    private(set) var isUnreadable = false
    @ObservationIgnored private let store: JSONFileStore<File>

    init(paths: AppPaths) {
        store = JSONFileStore(url: paths.file("command-aliases-v1.json"))
        reload()
    }

    func reload() {
        let exists = FileManager.default.fileExists(atPath: store.url.path)
        let file = store.load()
        isUnreadable = exists && (file == nil || file?.version != 1)
        aliases = isUnreadable ? [:] : file?.aliases ?? [:]
    }

    /// Aliases in the shape `CommandSearch.rank(aliases:)` expects.
    var searchAliases: [String: [String]] { aliases.mapValues { [$0] } }

    func setAlias(_ alias: String, for commandID: String) {
        guard !isUnreadable else { return }
        let trimmed = alias.trimmingCharacters(in: .whitespacesAndNewlines)
        aliases[commandID] = trimmed.isEmpty ? nil : String(trimmed.prefix(40))
        try? store.save(File(aliases: aliases))
    }
}
