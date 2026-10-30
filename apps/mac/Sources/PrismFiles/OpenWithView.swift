import AppKit
import PrismCore
import PrismKit
import SwiftUI

/// Chooses an app to open a file with. The default app comes first, then the others by name.
@MainActor
@Observable
final class OpenWithModel {
    struct Application: Identifiable, Hashable {
        var id: String { url.path }
        let url: URL
        let name: String
        let isDefault: Bool
    }

    let hit: FileHit
    var query = "" { didSet { if query != oldValue { selection = 0 } } }
    var selection = 0
    private(set) var applications: [Application] = []

    init(hit: FileHit) {
        self.hit = hit
    }

    func load() {
        let workspace = NSWorkspace.shared
        let defaultApp = workspace.urlForApplication(toOpen: hit.url)
        var seen = Set<String>()
        var apps: [Application] = []
        for url in [defaultApp].compactMap({ $0 }) + workspace.urlsForApplications(toOpen: hit.url) {
            guard seen.insert(url.resolvingSymlinksInPath().path).inserted else { continue }
            let name = FileManager.default.displayName(atPath: url.path).replacingOccurrences(of: ".app", with: "")
            apps.append(Application(url: url, name: name, isDefault: url == defaultApp))
        }
        applications = [apps.first].compactMap { $0 }.filter(\.isDefault)
            + apps.filter { !$0.isDefault }.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    var filtered: [Application] {
        CommandSearch.rank(applications, query: query) { SearchCandidate(id: $0.id, title: $0.name) }
    }

    var selected: Application? {
        let items = filtered
        return items.indices.contains(selection) ? items[selection] : nil
    }

    func open(_ application: Application) {
        NSWorkspace.shared.open([hit.url], withApplicationAt: application.url, configuration: NSWorkspace.OpenConfiguration())
    }
}

struct OpenWithView: View {
    @ViewState private var model: OpenWithModel
    let onOpen: () -> Void
    let onCancel: () -> Void

    init(hit: FileHit, onOpen: @escaping () -> Void, onCancel: @escaping () -> Void) {
        _model = ViewState(initialValue: OpenWithModel(hit: hit))
        self.onOpen = onOpen
        self.onCancel = onCancel
    }

    var body: some View {
        VStack(spacing: 0) {
            PrismScreenHeader {
                PrismBackButton(help: Text("Back", bundle: .module), action: onCancel)
                HStack(spacing: 9) {
                    PrismSearchGlyph()
                    ScreenSearchField(
                        text: Binding(get: { model.query }, set: { model.query = $0 }),
                        placeholder: String(localized: "Open “\(model.hit.name)” with…", bundle: .module),
                        onCommand: handle
                    )
                }
            }
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(Array(model.filtered.enumerated()), id: \.element.id) { index, app in
                            HStack(spacing: 10) {
                                Image(nsImage: AppIconCache.shared.icon(forPath: app.url.path)).resizable().frame(width: 26, height: 26)
                                Text(verbatim: app.name)
                                    .font(.prism(13, weight: 550))
                                    .foregroundStyle(PrismTheme.text)
                                Spacer()
                                if app.isDefault {
                                    Text("Default", bundle: .module).font(.prism(11)).foregroundStyle(PrismTheme.textMuted)
                                }
                            }
                            .padding(.horizontal, 11)
                            .frame(minHeight: PrismPaletteMetrics.rowHeight)
                            .prismRowBackground(isSelected: index == model.selection)
                            .contentShape(Rectangle())
                            .id(app.id)
                            .onTapGesture { open(app) }
                        }
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                }
                .scrollIndicators(.never)
                .onChange(of: model.selection) {
                    if let app = model.selected { proxy.scrollTo(app.id) }
                }
            }
            PrismStatusBar {
                HStack(spacing: 7) {
                    Image(nsImage: AppIconCache.shared.icon(forPath: model.hit.path)).resizable().frame(width: 16, height: 16)
                    Text(verbatim: model.hit.name).lineLimit(1)
                }
                .padding(.horizontal, 7)
            } trailing: {
                PrismStatusAction(Text("Open", bundle: .module), keys: "↵", isPrimary: true) {
                    if let app = model.selected { open(app) }
                }
                .disabled(model.selected == nil)
            }
        }
        .task { model.load() }
    }

    private func handle(_ command: SearchFieldCommand) -> Bool {
        let count = model.filtered.count
        switch command {
        case .up: model.selection = max(model.selection - 1, 0)
        case .down: model.selection = min(model.selection + 1, max(count - 1, 0))
        case .submit: if let app = model.selected { open(app) }
        case .cancel:
            if !model.query.isEmpty { model.query = "" } else { onCancel() }
        default: return false
        }
        return true
    }

    private func open(_ app: OpenWithModel.Application) {
        model.open(app)
        onOpen()
    }
}
