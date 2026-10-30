import AppKit
import PrismCore
import PrismKit

/// Deliberate web intents, as in the Tauri `web` provider: an `http(s)://` address opens in the default browser and
/// `web <query>` searches. Nothing touches the network until the user runs the row.
@MainActor
final class WebProvider: PaletteProvider {
    let id = "web"

    func results(for query: String) async -> [PaletteItem] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        switch WebIntent(trimmed) {
        case .url(let url)?:
            return [Self.item(id: "web:url", title: String(localized: "Open \(Self.bounded(trimmed))", bundle: .module),
                              subtitle: String(localized: "Open this HTTP(S) URL in the default browser", bundle: .module),
                              action: String(localized: "Open in default browser", bundle: .module), url: url, matchedQuery: trimmed)]
        case .search(let terms)?:
            guard let url = WebIntent.searchURL(terms) else { return [] }
            return [Self.searchItem(terms, url: url, matchedQuery: trimmed)]
        case nil:
            return []
        }
    }

    static func searchItem(_ terms: String, url: URL, matchedQuery: String?) -> PaletteItem {
        item(id: "web:search", title: String(localized: "Search the web for “\(bounded(terms))”", bundle: .module),
             subtitle: String(localized: "Explicit web search", bundle: .module),
             action: String(localized: "Search in default browser", bundle: .module), url: url, matchedQuery: matchedQuery)
    }

    private static func item(id: String, title: String, subtitle: String, action: String, url: URL, matchedQuery: String?) -> PaletteItem {
        PaletteItem(
            candidate: SearchCandidate(id: id, title: title, subtitle: subtitle, section: String(localized: "Web", bundle: .module),
                                       rankingBoost: 72, matchedQuery: matchedQuery),
            icon: .symbol("globe"),
            accessory: String(localized: "Web", bundle: .module),
            actions: [
                PaletteAction(id: id == "web:url" ? "open-web-url" : "search-web", title: action, systemImage: "safari") {
                    NSWorkspace.shared.open(url)
                    return .dismiss
                },
                PaletteAction(id: "copy-url", title: String(localized: "Copy URL", bundle: .module), systemImage: "doc.on.doc",
                              shortcut: .init("c", modifiers: [.command, .shift])) {
                    PasteService.copy(url.absoluteString)
                    return .notify(String(localized: "Copied to Clipboard", bundle: .module))
                },
            ]
        )
    }

    static func bounded(_ value: String, limit: Int = 88) -> String {
        value.count <= limit ? value : String(value.prefix(limit - 1)) + "…"
    }
}

/// A web search offered after every other result, so a query with no local match still has somewhere to go.
@MainActor
final class WebFallbackProvider: PaletteProvider {
    let id = "web-fallback"
    var ranking: PaletteRanking { .appended }

    func results(for query: String) async -> [PaletteItem] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, WebIntent(trimmed) == nil, let url = WebIntent.searchURL(trimmed) else { return [] }
        var item = WebProvider.searchItem(trimmed, url: url, matchedQuery: nil)
        item.candidate.id = "web:fallback"
        item.candidate.subtitle = String(localized: "Search in default browser", bundle: .module)
        return [item]
    }
}
