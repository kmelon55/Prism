import AppKit
import Observation
import PrismKit
import SwiftUI
import UniformTypeIdentifiers

@MainActor
@Observable
final class LibrarySettingsState {
    var accessibility = SnippetExpander.hasAccessibility
    var inputMonitoring = SnippetExpander.hasInputMonitoring
    var favoriteError: String?
}

/// Tauri's Settings → Snippets (`SnippetExpansionSettings`): the expansion switch, its status and permissions,
/// excluded apps, then the native library settings (favorites order and entry counts) as further groups.
struct LibrarySettingsView: View {
    let services: LibraryServices
    @Bindable var expander: SnippetExpander
    @Bindable var state: LibrarySettingsState

    private var model: LibraryModel { services.model }

    /// Words the settings sidebar search matches for this pane.
    static var keywords: [String] {
        ["Snippet expansion", "Accessibility", "Input Monitoring", "Excluded Apps", "Favorites", "Quicklinks", "Notes", "Library"]
            .map(L10n.tr)
    }

    var body: some View {
        PrismSettingsPage(L10n.tr("Snippets")) {
            expansionGroup
            exclusionsGroup
            favoritesGroup
            libraryGroup
        }
        .task {
            await model.loadIfNeeded()
            expander.reloadSnippets()
            while !Task.isCancelled {
                refreshStatus()
                try? await Task.sleep(for: .seconds(2))
            }
        }
    }

    private func refreshStatus() {
        state.accessibility = SnippetExpander.hasAccessibility
        state.inputMonitoring = SnippetExpander.hasInputMonitoring
        expander.update()
    }

    // MARK: Snippet expansion

    private var expansionGroup: some View {
        PrismSettingsGroup {
            PrismSettingsRow(Text(verbatim: L10n.tr("Snippet expansion")),
                             detail: Text(verbatim: L10n.tr("Off by default. Type a saved keyword such as ;email, then a space to expand it in a compatible text field."))) {
                Toggle(isOn: Binding(get: { expander.config.enabled }, set: { expander.setEnabled($0) })) { EmptyView() }
                    .toggleStyle(.prism)
                    .labelsHidden()
            }
            PrismSettingsRow(Text(verbatim: L10n.tr("Status")),
                             detail: Text(verbatim: String(format: L10n.tr("%lld keywords ready"), expander.registeredCount))) {
                HStack(spacing: 8) {
                    PrismBadge(statusText, tone: statusTone)
                    Button { refreshStatus() } label: {
                        Image(systemName: "arrow.clockwise").font(.system(size: 11, weight: .semibold))
                    }
                    .buttonStyle(.prismGhost)
                    .help(L10n.tr("Refresh status"))
                }
            }
            permissionRow(title: L10n.tr("Accessibility"), detail: L10n.tr("Deletes the keyword and pastes the snippet."),
                          granted: state.accessibility,
                          settingsURL: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")
            permissionRow(title: L10n.tr("Input Monitoring"), detail: L10n.tr("Notices when you type a keyword."),
                          granted: state.inputMonitoring,
                          settingsURL: "x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent")
            if let error = expander.lastError {
                SnippetSettingsAlert(text: error)
            }
            PrismSettingsNote(Text(verbatim: L10n.tr("Works with keyboard layouts such as ABC or U.S. Keys typed with Korean and other input methods, in password fields and in excluded apps are ignored. Snippets with {date}, {time} or {clipboard} are not expanded. No typing history is saved.")))
                .padding(.top, 6)
        }
    }

    private var statusText: String {
        if expander.isActive { return L10n.tr("Listening in text fields") }
        if expander.config.enabled { return L10n.tr("Paused — needs permission") }
        return L10n.tr("Off")
    }

    private var statusTone: PrismBadge.Tone {
        expander.isActive ? .success : expander.config.enabled ? .warning : .neutral
    }

    private func permissionRow(title: String, detail: String, granted: Bool, settingsURL: String) -> some View {
        PrismSettingsRow(Text(verbatim: title), detail: Text(verbatim: detail)) {
            if granted {
                PrismBadge(L10n.tr("Allowed"), tone: .success)
            } else {
                HStack(spacing: 8) {
                    PrismBadge(L10n.tr("Needs access"), tone: .warning)
                    Button {
                        expander.requestPermissions()
                        if let url = URL(string: settingsURL) { NSWorkspace.shared.open(url) }
                    } label: {
                        Label { Text(verbatim: L10n.tr("Open System Settings")) } icon: { Image(systemName: "arrow.up.forward.square") }
                    }
                    .buttonStyle(.prism)
                }
            }
        }
    }

    // MARK: Exclusions

    private var exclusionsGroup: some View {
        PrismSettingsGroup(Text(verbatim: L10n.tr("Excluded Apps"))) {
            Button { addExcludedApp() } label: {
                Label { Text(verbatim: L10n.tr("Add App…")) } icon: { Image(systemName: "plus") }
            }
            .buttonStyle(.prism)
            .disabled(expander.config.excludedApps.count >= SnippetExpansionConfig.maxExclusions)
        } content: {
            SnippetSettingsDivider()
            if expander.config.excludedApps.isEmpty {
                SnippetSettingsEmptyRow(text: L10n.tr("No excluded apps"))
            }
            ForEach(expander.config.excludedApps, id: \.self) { bundleID in
                let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID)
                SnippetSettingsListRow(
                    title: url.map { FileManager.default.displayName(atPath: $0.path).replacingOccurrences(of: ".app", with: "") } ?? bundleID,
                    detail: bundleID
                ) {
                    Image(nsImage: url.map { NSWorkspace.shared.icon(forFile: $0.path) }
                        ?? NSImage(systemSymbolName: "app", accessibilityDescription: nil)!)
                        .resizable()
                } accessory: {
                    SnippetSettingsIconButton(systemImage: "xmark", help: L10n.tr("Remove")) {
                        expander.setExcludedApps(expander.config.excludedApps.filter { $0 != bundleID })
                    }
                }
            }
            PrismSettingsNote(Text(verbatim: L10n.tr("Password managers and Prism are always excluded.")))
                .padding(.top, 12)
        }
    }

    private func addExcludedApp() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.application]
        panel.allowsMultipleSelection = true
        panel.directoryURL = URL(filePath: "/Applications")
        panel.prompt = L10n.tr("Exclude")
        guard panel.runModal() == .OK else { return }
        let ids = panel.urls.compactMap { Bundle(url: $0)?.bundleIdentifier }
        expander.setExcludedApps(expander.config.excludedApps + ids)
    }

    // MARK: Favorites

    private var favoritesGroup: some View {
        PrismSettingsGroup(Text(verbatim: L10n.tr("Favorites"))) {
            SnippetSettingsDivider()
            if model.favorites.isEmpty {
                SnippetSettingsEmptyRow(text: L10n.tr("Add favorites from a search result's actions with ⌘⇧F."))
            }
            ForEach(Array(model.favorites.enumerated()), id: \.element.id) { index, favorite in
                SnippetSettingsListRow(title: favorite.title.isEmpty ? favorite.id : favorite.title, detail: nil) {
                    Image(systemName: "star").font(.system(size: 13)).foregroundStyle(PrismTheme.textSecondary)
                } accessory: {
                    HStack(spacing: 2) {
                        SnippetSettingsIconButton(systemImage: "chevron.up", help: L10n.tr("Move Up")) { move(favorite, by: -1) }
                            .disabled(index == 0)
                        SnippetSettingsIconButton(systemImage: "chevron.down", help: L10n.tr("Move Down")) { move(favorite, by: 1) }
                            .disabled(index == model.favorites.count - 1)
                        SnippetSettingsIconButton(systemImage: "xmark", help: L10n.tr("Remove from Favorites")) {
                            Task { await run { try await services.favorites.remove(id: favorite.id) } }
                        }
                    }
                }
            }
            if let favoriteError = state.favoriteError {
                SnippetSettingsAlert(text: favoriteError).padding(.top, 8)
            }
            PrismSettingsNote(Text(verbatim: L10n.tr("Favorites lead the empty search, in this order.")))
                .padding(.top, 12)
        }
    }

    private func move(_ favorite: LibraryFavorite, by offset: Int) {
        Task { await run { try await services.favorites.move(id: favorite.id, by: offset) } }
    }

    private func run(_ body: () async throws -> Void) async {
        do {
            try await body()
            state.favoriteError = nil
        } catch {
            state.favoriteError = error.localizedDescription
        }
    }

    // MARK: Library

    private var libraryGroup: some View {
        PrismSettingsGroup(Text(verbatim: L10n.tr("Library"))) {
            countRow(L10n.tr("Quicklinks"), count: model.entries(of: [.link, .path]).count,
                     action: L10n.tr("New Quicklink…"), systemImage: "plus") { services.create(.link) }
            countRow(L10n.tr("Snippets"), count: model.entries(of: [.snippet]).count,
                     action: L10n.tr("New Snippet…"), systemImage: "plus") { services.create(.snippet) }
            countRow(L10n.tr("Notes"), count: model.entries(of: [.note]).count,
                     action: L10n.tr("Open Notes"), systemImage: "arrow.up.forward") { services.notes.show() }
            PrismSettingsNote(Text(verbatim: L10n.tr("Stored on this Mac in library-v1.sqlite3. Up to 1,000 entries and 128 KB per entry.")))
                .padding(.top, 6)
        }
    }

    private func countRow(_ title: String, count: Int, action: String, systemImage: String,
                          perform: @escaping () -> Void) -> some View {
        PrismSettingsRow(Text(verbatim: title)) {
            HStack(spacing: 12) {
                Text(verbatim: "\(count)")
                    .font(.system(size: 12))
                    .monospacedDigit()
                    .foregroundStyle(PrismTheme.textSecondary)
                Button(action: perform) {
                    Label { Text(verbatim: action) } icon: { Image(systemName: systemImage) }
                }
                .buttonStyle(.prism)
            }
        }
    }
}
