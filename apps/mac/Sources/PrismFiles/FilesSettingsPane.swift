import AppKit
import PrismKit
import SwiftUI

enum FilesSettingsPane {
    @MainActor
    static func make(service: FileSearchService) -> SettingsPane {
        SettingsPane(id: "files", title: String(localized: "Files", bundle: .module.prismLocalized), systemImage: "folder", group: .tools, order: 30,
                     keywords: keywords) {
            FilesSettingsView(service: service)
        }
    }

    static var keywords: [String] {
        ["Search your home folder with Spotlight", "Additional Search Folders", "Add Folder…", "Refresh Index"]
            .map { String(localized: String.LocalizationValue($0), bundle: .module.prismLocalized) }
    }
}

/// Settings → Files in the Tauri settings design: flat rows, the folder list as hairline-separated rows with
/// quiet remove buttons, and `.prism` buttons.
struct FilesSettingsView: View {
    @Bindable var service: FileSearchService
    @ViewState private var error: String?

    var body: some View {
        PrismSettingsPage(String(localized: "Files", bundle: .module.prismLocalized)) {
            PrismSettingsGroup(Text("Search", bundle: .module.prismLocalized)) {
                PrismSettingsRow(Text("Search your home folder with Spotlight", bundle: .module.prismLocalized),
                                 detail: Text("Prism matches file and folder names only and never reads file contents.", bundle: .module.prismLocalized)) {
                    Toggle(isOn: $service.spotlightEnabled) { EmptyView() }.toggleStyle(.prism).labelsHidden()
                }
            }

            PrismSettingsGroup(Text("Additional Search Folders", bundle: .module.prismLocalized)) {
                Button { chooseFolder() } label: {
                    Label { Text("Add Folder…", bundle: .module.prismLocalized) } icon: { Image(systemName: "plus") }
                }
                .buttonStyle(.prism)
                .disabled(service.roots.count >= SearchRootsStore.maxRoots)
            } content: {
                FilesSettingsDivider()
                if service.roots.isEmpty {
                    Text("No additional folders", bundle: .module.prismLocalized)
                        .font(.system(size: 12))
                        .foregroundStyle(PrismTheme.textMuted)
                        .frame(maxWidth: .infinity, minHeight: 50, alignment: .leading)
                    FilesSettingsDivider()
                }
                ForEach(service.roots) { root in
                    folderRow(root)
                }
                if let error {
                    HStack(alignment: .firstTextBaseline, spacing: 7) {
                        Image(systemName: "exclamationmark.triangle")
                        Text(verbatim: error).fixedSize(horizontal: false, vertical: true)
                    }
                    .font(.system(size: 11))
                    .foregroundStyle(PrismTheme.danger)
                    .padding(.top, 10)
                }
                PrismSettingsNote(Text("Your home folder is searched automatically. Add other folders as needed, up to 12.", bundle: .module.prismLocalized))
                    .padding(.top, 12)
            }

            if !service.roots.isEmpty {
                PrismSettingsGroup(Text("Index", bundle: .module.prismLocalized)) {
                    PrismSettingsRow(indexTitle, detail: service.isLimited && !service.isIndexing
                                     ? Text("Some folders couldn't be read or the index reached its limit.", bundle: .module.prismLocalized) : nil) {
                        HStack(spacing: 8) {
                            if service.isIndexing {
                                ProgressView().controlSize(.small).scaleEffect(0.7).frame(width: 16, height: 16)
                            }
                            Button { service.refresh(force: true) } label: {
                                Label { Text("Refresh Index", bundle: .module.prismLocalized) } icon: { Image(systemName: "arrow.clockwise") }
                            }
                            .buttonStyle(.prism)
                            .disabled(service.isIndexing)
                        }
                    }
                }
            }
        }
        .onAppear { service.reloadRoots() }
    }

    private var indexTitle: Text {
        service.isIndexing
            ? Text("Updating the file index…", bundle: .module.prismLocalized)
            : Text("\(service.indexedCount) items indexed", bundle: .module.prismLocalized)
    }

    private func folderRow(_ root: SearchRoot) -> some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Image(nsImage: AppIconCache.shared.icon(forPath: root.path)).resizable().frame(width: 20, height: 20)
                VStack(alignment: .leading, spacing: 2) {
                    Text(verbatim: FileManager.default.displayName(atPath: root.path))
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(PrismTheme.text)
                        .lineLimit(1)
                    Text(verbatim: FileHit.abbreviate(root.path))
                        .font(.system(size: 11))
                        .foregroundStyle(PrismTheme.textMuted)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Spacer(minLength: 12)
                Button { remove(root) } label: {
                    Image(systemName: "xmark").font(.system(size: 10, weight: .semibold)).frame(width: 14, height: 14)
                }
                .buttonStyle(.prismGhost)
                .help(Text("Exclude \(root.path) from search", bundle: .module.prismLocalized))
            }
            .padding(.horizontal, 4)
            .frame(minHeight: 50)
            FilesSettingsDivider()
        }
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.message = String(localized: "Choose a folder to search by filename", bundle: .module.prismLocalized)
        panel.prompt = String(localized: "Add Folder", bundle: .module.prismLocalized)
        let completion: (NSApplication.ModalResponse) -> Void = { response in
            guard response == .OK, let url = panel.url else { return }
            MainActor.assumeIsolated {
                do {
                    try service.addRoot(url)
                    error = nil
                } catch {
                    self.error = error.localizedDescription
                }
            }
        }
        if let window = NSApp.keyWindow { panel.beginSheetModal(for: window, completionHandler: completion) } else { panel.begin(completionHandler: completion) }
    }

    private func remove(_ root: SearchRoot) {
        do {
            try service.removeRoot(root)
            error = nil
        } catch {
            self.error = error.localizedDescription
        }
    }
}

/// A full-width hairline between folder rows.
private struct FilesSettingsDivider: View {
    var body: some View {
        Rectangle().fill(PrismTheme.separator).frame(height: 1)
    }
}
