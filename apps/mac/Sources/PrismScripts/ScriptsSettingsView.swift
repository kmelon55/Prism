import AppKit
import PrismKit
import SwiftUI

/// Settings → Scripts, laid out like the Tauri "scripts" section: local directories as flat rows, the command
/// registry status with its refresh button, the discovered commands, and the "Local and explicit" callout.
struct ScriptsSettingsView: View {
    let model: ScriptsModel
    let actions: ScriptActions

    static var keywords: [String] {
        ["Script command folders", "Command registry", "Registry status", "Refresh Commands", "Script commands"]
            .map { ScriptStrings.localized(String.LocalizationValue($0)) }
    }

    var body: some View {
        PrismSettingsPage(ScriptStrings.localized("Scripts")) {
            PrismSettingsGroup(Text("Local directories", bundle: .module)) {
                Button { chooseDirectories() } label: {
                    Label { Text("Add Folder…", bundle: .module) } icon: { Image(systemName: "plus") }
                }
                .buttonStyle(.prism)
                .disabled(!model.canAddDirectory)
            } content: {
                PrismSettingsRow(Text("Script command folders", bundle: .module),
                                 detail: Text("Prism lists executable scripts placed directly in these folders and picks up changes automatically. Raycast script commands work as they are.", bundle: .module))
                ScriptsSettingsDivider()
                if model.directories.isEmpty {
                    Text("No script directories configured.", bundle: .module)
                        .font(.system(size: 12))
                        .foregroundStyle(PrismTheme.textMuted)
                        .frame(maxWidth: .infinity, minHeight: 50, alignment: .leading)
                    ScriptsSettingsDivider()
                } else {
                    ForEach(model.directories, id: \.self) { directory in
                        directoryRow(directory)
                    }
                }
            }
            .dropDestination(for: URL.self) { urls, _ in
                let folders = urls.filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }
                model.addDirectories(folders)
                return !folders.isEmpty
            }

            PrismSettingsGroup(Text("Command registry", bundle: .module)) {
                PrismSettingsRow(Text("Registry status", bundle: .module), detail: Text(verbatim: statusText)) {
                    Button { model.refresh() } label: {
                        Label { Text("Refresh Commands", bundle: .module) } icon: {
                            if model.isRefreshing {
                                ProgressView().controlSize(.small).scaleEffect(0.6).frame(width: 12, height: 12)
                            } else {
                                Image(systemName: "arrow.clockwise")
                            }
                        }
                    }
                    .buttonStyle(.prism)
                    .disabled(model.isRefreshing)
                }
                if let error = model.refreshError ?? model.historyError {
                    HStack(alignment: .firstTextBaseline, spacing: 7) {
                        Image(systemName: "exclamationmark.triangle")
                        Text(verbatim: ScriptStrings.localize(error))
                            .textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .font(.system(size: 11))
                    .foregroundStyle(PrismTheme.danger)
                    .padding(.bottom, 8)
                }
            }

            if !model.commands.isEmpty {
                PrismSettingsGroup(Text("Script commands", bundle: .module)) {
                    ScriptsSettingsDivider()
                    ForEach(model.commands) { command in
                        commandRow(command)
                    }
                }
            }

            PrismCallout(systemImage: "terminal", title: Text("Local and explicit", bundle: .module),
                         detail: Text("Scripts run only when you choose them, with your arguments passed literally. Output is kept on this Mac, and runs that accept a password are never saved.", bundle: .module))
        }
        .task { await model.bootstrap() }
    }

    private var statusText: String {
        if model.isRefreshing && model.lastRefresh == nil { return ScriptStrings.localized("Refreshing…") }
        guard let result = model.lastRefresh else { return model.refreshError == nil ? "—" : ScriptStrings.localized("Refresh failed. The previous registry remains active.") }
        let summary = ScriptStrings.localized("\(result.commands.count) commands from \(result.scannedDirectories) folders")
        let skipped = result.skippedEntries > 0 ? ScriptStrings.localized(" · \(result.skippedEntries) skipped") : ""
        if model.refreshError != nil { return ScriptStrings.localized("Refresh failed. The previous registry remains active.") }
        return summary + skipped
    }

    private func directoryRow(_ directory: String) -> some View {
        let exists = FileManager.default.fileExists(atPath: directory)
        return VStack(spacing: 0) {
            HStack(spacing: 12) {
                Image(nsImage: AppIconCache.shared.icon(forPath: exists ? directory : "/System/Library/CoreServices/Finder.app"))
                    .resizable()
                    .frame(width: 20, height: 20)
                    .opacity(exists ? 1 : 0.4)
                VStack(alignment: .leading, spacing: 2) {
                    Text(verbatim: (directory as NSString).lastPathComponent)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(PrismTheme.text)
                        .lineLimit(1)
                    Text(verbatim: (directory as NSString).abbreviatingWithTildeInPath)
                        .font(.system(size: 11))
                        .foregroundStyle(PrismTheme.textMuted)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Spacer(minLength: 12)
                if !exists {
                    PrismBadge(ScriptStrings.localized("Folder not found"), tone: .warning)
                } else if let count = model.commandCountByDirectory[directory] {
                    Text("\(count) commands", bundle: .module)
                        .font(.system(size: 11))
                        .foregroundStyle(PrismTheme.textMuted)
                }
                HStack(spacing: 2) {
                    Button {
                        NSWorkspace.shared.activateFileViewerSelecting([URL(filePath: directory)])
                    } label: {
                        Image(systemName: "folder").font(.system(size: 11, weight: .medium)).frame(width: 14, height: 14)
                    }
                    .buttonStyle(.prismGhost)
                    .help(Text("Show in Finder", bundle: .module))
                    .disabled(!exists)
                    Button {
                        model.removeDirectory(directory)
                    } label: {
                        Image(systemName: "xmark").font(.system(size: 10, weight: .semibold)).frame(width: 14, height: 14)
                    }
                    .buttonStyle(.prismGhost)
                    .help(Text("Remove", bundle: .module))
                    .accessibilityLabel(Text("Remove script directory \(directory)", bundle: .module))
                }
            }
            .padding(.horizontal, 4)
            .frame(minHeight: 50)
            ScriptsSettingsDivider()
        }
        .contextMenu {
            Button { NSWorkspace.shared.activateFileViewerSelecting([URL(filePath: directory)]) } label: { Text("Show in Finder", bundle: .module) }
            Button(role: .destructive) { model.removeDirectory(directory) } label: { Text("Remove", bundle: .module) }
        }
    }

    private func commandRow(_ command: ScriptCommandSummary) -> some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                PaletteIconImage(icon: actions.icon(for: command))
                    .frame(width: 20, height: 20)
                VStack(alignment: .leading, spacing: 2) {
                    Text(verbatim: command.title)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(PrismTheme.text)
                        .lineLimit(1)
                    Text(verbatim: detail(command))
                        .font(.system(size: 11))
                        .foregroundStyle(PrismTheme.textMuted)
                        .lineLimit(1)
                }
                Spacer(minLength: 12)
                if let error = command.argumentError {
                    Image(systemName: "exclamationmark.triangle")
                        .font(.system(size: 12))
                        .foregroundStyle(PrismTheme.warning)
                        .help(ScriptStrings.localize(error))
                }
            }
            .padding(.horizontal, 4)
            .frame(minHeight: 50)
            ScriptsSettingsDivider()
        }
        .contextMenu {
            Button { _ = actions.reveal(command.id) } label: { Text("Show in Finder", bundle: .module) }
            Button { _ = actions.edit(command.id) } label: { Text("Edit Script", bundle: .module) }
        }
    }

    private func detail(_ command: ScriptCommandSummary) -> String {
        var parts = [modeTitle(command.mode), ScriptStrings.localized("Timeout: \(command.timeoutSeconds) seconds")]
        if !command.arguments.isEmpty { parts.append(command.arguments.map(\.placeholder).joined(separator: ", ")) }
        if let package = command.packageName { parts.insert(package, at: 0) }
        return parts.joined(separator: " · ")
    }

    private func modeTitle(_ mode: ScriptOutputMode) -> String {
        switch mode {
        case .fullOutput: ScriptStrings.localized("Full output")
        case .compact: ScriptStrings.localized("Compact")
        case .silent: ScriptStrings.localized("Silent")
        case .inline: ScriptStrings.localized("Inline")
        }
    }

    private func chooseDirectories() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = true
        panel.prompt = ScriptStrings.localized("Add Folder")
        panel.message = ScriptStrings.localized("Choose folders that contain script commands.")
        panel.begin { response in
            guard response == .OK else { return }
            let urls = panel.urls
            MainActor.assumeIsolated { model.addDirectories(urls) }
        }
    }
}

/// A full-width hairline between list rows.
private struct ScriptsSettingsDivider: View {
    var body: some View {
        Rectangle().fill(PrismTheme.separator).frame(height: 1)
    }
}
