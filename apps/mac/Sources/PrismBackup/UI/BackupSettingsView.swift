import PrismKit
import SwiftUI

/// The Tauri Backup & Restore section: the Raycast import first, then the local backup with its categories,
/// actions and the review of a chosen file.
struct BackupSettingsView: View {
    @Bindable var backup: BackupModel
    let raycast: RaycastImportModel?

    @ViewState private var confirmLibrary = false
    @ViewState private var confirmPreferences = false

    var body: some View {
        PrismSettingsPage(L10n.tr("Backup & Restore")) {
            if let raycast {
                VStack(alignment: .leading, spacing: 26) {
                    RaycastImportSection(model: raycast)
                    Rectangle().fill(PrismTheme.separator).frame(height: 1)
                }
                .padding(.bottom, -2)
            }
            localBackup
            if let review = backup.review {
                reviewGroup(review)
                if review.categories.preferences { preferencesGroup(review) }
            }
        }
    }

    // MARK: Local backup

    private var localBackup: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 5) {
                Text("Local backup", bundle: .module).font(.system(size: 12, weight: .semibold)).foregroundStyle(PrismTheme.text)
                PrismSettingsNote(Text("Choose what to export or import. Existing library items win conflicts.", bundle: .module))
            }
            categories
            PrismDisclosure(Text("Backup contents & privacy", bundle: .module)) {
                VStack(alignment: .leading, spacing: 8) {
                    hint(Text("Safe preferences include appearance, language, and aliases. Keys, histories, permissions, script folders, and hotkeys are excluded.", bundle: .module))
                    hint(Text("Path references are optional. They restore saved paths only; file search roots and AI access are never granted. Missing targets remain unavailable until repaired.", bundle: .module))
                    hint(Text("Backup files are not encrypted. Keep them somewhere private. Maximum file size: 20 MB.", bundle: .module))
                }
                .padding(.leading, 15)
            }
            PrismSettingsRow(Text("Backup folder", bundle: .module), detail: lastBackupText) {
                HStack(spacing: 8) {
                    if let location = backup.location {
                        Button { backup.revealLocation() } label: {
                            HStack(spacing: 6) {
                                Image(nsImage: NSWorkspace.shared.icon(forFile: location.path)).resizable().frame(width: 16, height: 16)
                                Text(verbatim: location.lastPathComponent).lineLimit(1).truncationMode(.middle)
                            }
                        }
                        .buttonStyle(.prismGhost)
                        .help(location.path)
                    } else {
                        Text("Not chosen", bundle: .module).font(.system(size: 12)).foregroundStyle(PrismTheme.textMuted)
                    }
                    Button { backup.chooseLocation() } label: { Text("Choose…", bundle: .module) }
                        .buttonStyle(.prism)
                }
            }
            .padding(.vertical, -6)
            HStack(spacing: 8) {
                if backup.busy == .backup || backup.busy == .export || backup.busy == .review { ProgressView().controlSize(.small) }
                Spacer(minLength: 0)
                Button { Task { await backup.exportAs() } } label: {
                    iconLabel("square.and.arrow.down", Text("Export backup", bundle: .module))
                }
                .buttonStyle(.prism)
                .disabled(backup.isBusy || !backup.categories.any)
                Button { Task { await backup.chooseBackupToReview() } } label: {
                    iconLabel("square.and.arrow.up", Text("Choose backup to review", bundle: .module))
                }
                .buttonStyle(.prism)
                .disabled(backup.isBusy || !backup.categories.any)
                .help(Text("Nothing changes until you confirm the review.", bundle: .module))
                Button { Task { await backup.backUpNow() } } label: {
                    iconLabel("externaldrive", Text("Back Up Now", bundle: .module))
                }
                .buttonStyle(.prismPrimary)
                .keyboardShortcut("s", modifiers: [.command])
                .disabled(backup.isBusy || !backup.categories.any)
            }
            statusRow(for: [.backup, .export])
            if backup.review == nil { statusRow(for: [.review, .apply]) }
        }
    }

    private var lastBackupText: Text {
        if let date = backup.lastBackup {
            Text("Last backup: \(date.formatted(date: .abbreviated, time: .shortened))", bundle: .module)
        } else {
            Text("No backup yet", bundle: .module)
        }
    }

    private var categories: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Backup categories", bundle: .module).font(.system(size: 12, weight: .semibold)).foregroundStyle(PrismTheme.text)
            PrismFlowLayout(horizontalSpacing: 20, verticalSpacing: 12) {
                Toggle(isOn: $backup.categories.notes) { Text("Notes", bundle: .module) }
                Toggle(isOn: $backup.categories.snippets) { Text("Snippets", bundle: .module) }
                Toggle(isOn: $backup.categories.quicklinks) { Text("Quicklinks", bundle: .module) }
                Toggle(isOn: $backup.categories.pathLinks) { Text("Path references", bundle: .module) }
                    .help(Text("Saved paths only. File search folders and AI access are never granted.", bundle: .module))
                Toggle(isOn: $backup.categories.favorites) { Text("Favorites", bundle: .module) }
                Toggle(isOn: $backup.categories.preferences) { Text("Safe preferences", bundle: .module) }
                    .help(Text("Appearance, language and aliases. Keys, histories, permissions, script folders and hotkeys are never included.", bundle: .module))
            }
            .toggleStyle(.prismLeadingCheckbox)
            .disabled(backup.isBusy)
            if !backup.categories.any {
                Text("Select at least one backup category.", bundle: .module).font(.system(size: 11)).foregroundStyle(PrismTheme.danger)
            }
            Rectangle().fill(PrismTheme.separator).frame(height: 1)
        }
    }

    private func hint(_ text: Text) -> some View {
        text.font(.system(size: 12)).foregroundStyle(PrismTheme.textSecondary).lineSpacing(3)
            .fixedSize(horizontal: false, vertical: true)
    }

    private func iconLabel(_ systemImage: String, _ title: Text) -> some View {
        HStack(spacing: 6) {
            Image(systemName: systemImage).font(.system(size: 11))
            title
        }
    }

    // MARK: Review

    private func reviewGroup(_ review: BackupModel.Review) -> some View {
        PrismSettingsGroup(Text("Review “\(review.fileName)”", bundle: .module)) {
            Button { backup.closeReview() } label: { Text("Close review", bundle: .module) }
                .buttonStyle(.prismGhost)
                .disabled(backup.isBusy)
        } content: {
            VStack(alignment: .leading, spacing: 14) {
                hint(Text("Only new library items will be added. Missing library favorites are skipped. Review expires after 10 minutes or a library change.", bundle: .module))
                if !review.libraryRows.isEmpty {
                    countsTable(review)
                    if !review.pathReferences.isEmpty {
                        PrismDisclosure(Text("Review path targets", bundle: .module)) {
                            VStack(alignment: .leading, spacing: 10) {
                                ForEach(review.pathReferences) { reference in
                                    VStack(alignment: .leading, spacing: 3) {
                                        Text(verbatim: reference.title).font(.system(size: 12, weight: .semibold)).foregroundStyle(PrismTheme.text)
                                        Text(verbatim: reference.path).font(.system(size: 11, design: .monospaced)).foregroundStyle(PrismTheme.textSecondary)
                                            .lineLimit(1).truncationMode(.middle)
                                        Text(verbatim: pathStatus(reference)).font(.system(size: 11))
                                            .foregroundStyle(reference.status == .existing ? PrismTheme.textMuted : PrismTheme.warning)
                                    }
                                }
                            }
                            .padding(.leading, 15)
                        }
                    }
                    if !review.missingFavorites.isEmpty {
                        PrismDisclosure(Text("Favorites skipped because their library targets are missing", bundle: .module)) {
                            VStack(alignment: .leading, spacing: 6) {
                                ForEach(review.missingFavorites, id: \.id) { favorite in
                                    HStack {
                                        Text(verbatim: favorite.title).foregroundStyle(PrismTheme.text)
                                        Spacer()
                                        Text(verbatim: favorite.id).font(.system(size: 11, design: .monospaced)).foregroundStyle(PrismTheme.textMuted)
                                    }
                                    .font(.system(size: 12))
                                }
                            }
                            .padding(.leading, 15)
                        }
                    }
                    HStack(spacing: 8) {
                        if review.additions == 0 && !backup.libraryApplied {
                            PrismSettingsNote(Text("No new library items to import.", bundle: .module))
                        }
                        Spacer(minLength: 0)
                        if backup.busy == .apply { ProgressView().controlSize(.small) }
                        Button {
                            confirmLibrary = true
                        } label: {
                            if backup.libraryApplied {
                                iconLabel("checkmark", Text("Library restored", bundle: .module))
                            } else {
                                Text("Import \(review.additions) New Items", bundle: .module)
                            }
                        }
                        .buttonStyle(.prismPrimary)
                        .disabled(backup.isBusy || backup.libraryApplied || review.additions == 0)
                        .confirmationDialog(Text("Import \(review.additions) new library items?", bundle: .module), isPresented: $confirmLibrary) {
                            Button { Task { await backup.applyLibrary() } } label: { Text("Import", bundle: .module) }
                        } message: {
                            Text("Only new items are added. Existing items are kept and nothing is deleted.", bundle: .module)
                        }
                    }
                }
                statusRow(for: [.apply])
            }
        }
    }

    /// `.backup-review table`: right-aligned counts with hairlines between rows.
    private func countsTable(_ review: BackupModel.Review) -> some View {
        Grid(alignment: .trailing, horizontalSpacing: 18, verticalSpacing: 0) {
            GridRow {
                Text("Category", bundle: .module).gridColumnAlignment(.leading)
                Text("In file", bundle: .module)
                Text("Add", bundle: .module)
                Text("Conflicts kept", bundle: .module)
                Text("Skipped", bundle: .module)
            }
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(PrismTheme.textMuted)
            .padding(.vertical, 7)
            Rectangle().fill(PrismTheme.separator).frame(height: 1).gridCellUnsizedAxes(.horizontal)
            ForEach(review.libraryRows, id: \.kind) { row in
                GridRow {
                    Text(verbatim: L10n.tr(row.title)).foregroundStyle(PrismTheme.text).frame(maxWidth: .infinity, alignment: .leading)
                    Text(verbatim: "\(row.counts.total)")
                    Text(verbatim: "\(row.counts.added)").foregroundStyle(row.counts.added > 0 ? PrismTheme.text : PrismTheme.textMuted)
                    Text(verbatim: "\(row.counts.conflicts)")
                    Text(verbatim: "\(row.counts.skipped)")
                }
                .font(.system(size: 11))
                .monospacedDigit()
                .foregroundStyle(PrismTheme.textSecondary)
                .padding(.vertical, 7)
                Rectangle().fill(PrismTheme.separator).frame(height: 1).gridCellUnsizedAxes(.horizontal)
            }
        }
    }

    private func preferencesGroup(_ review: BackupModel.Review) -> some View {
        PrismSettingsGroup(Text("Restore safe preferences separately", bundle: .module)) {
            if let preferences = review.preferences {
                let added = review.aliasReview.filter { $0.status == .add }.count
                // `.backup-preferences dl`: label over value, side by side.
                PrismFlowLayout(horizontalSpacing: 22, verticalSpacing: 12) {
                    term(Text("Language", bundle: .module), languageName(preferences.language))
                    term(Text("Appearance", bundle: .module), themeName(preferences.theme))
                    term(Text("Application icons", bundle: .module), onOff(preferences.showApplicationIcons))
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Aliases in backup", bundle: .module).foregroundStyle(PrismTheme.textSecondary)
                        Text("\(added) to add · \(review.aliasReview.count - added) kept or skipped", bundle: .module).foregroundStyle(PrismTheme.text)
                    }
                }
                .font(.system(size: 12))
                .padding(.bottom, 14)
                VStack(alignment: .leading, spacing: 14) {
                    if !review.aliasReview.isEmpty {
                        PrismDisclosure(Text("Review alias changes", bundle: .module)) {
                            VStack(alignment: .leading, spacing: 8) {
                                ForEach(review.aliasReview) { alias in
                                    HStack(alignment: .firstTextBaseline) {
                                        VStack(alignment: .leading, spacing: 2) {
                                            Text(verbatim: alias.alias).font(.system(size: 12, weight: .semibold)).foregroundStyle(PrismTheme.text)
                                            Text(verbatim: alias.id).font(.system(size: 11, design: .monospaced)).foregroundStyle(PrismTheme.textMuted)
                                        }
                                        Spacer()
                                        Text(verbatim: aliasStatus(alias)).font(.system(size: 11))
                                            .foregroundStyle(alias.status == .add ? PrismTheme.text : PrismTheme.textMuted)
                                    }
                                }
                            }
                            .padding(.leading, 15)
                        }
                    }
                    hint(Text("This replaces appearance and language. Existing aliases and alias conflicts are kept. Library import is a separate operation.", bundle: .module))
                    PrismSettingsNote(Text("Language applies the next time Prism opens. Opacity, blur and reduce motion are kept for the Tauri app; this version follows the system.", bundle: .module))
                    HStack(spacing: 8) {
                        Spacer(minLength: 0)
                        if backup.busy == .preferences { ProgressView().controlSize(.small) }
                        Button { confirmPreferences = true } label: {
                            if backup.preferencesApplied {
                                iconLabel("checkmark", Text("Safe preferences restored", bundle: .module))
                            } else {
                                Text("Restore Appearance, Language, and Aliases", bundle: .module)
                            }
                        }
                        .buttonStyle(.prism)
                        .disabled(backup.isBusy || backup.preferencesApplied)
                        .confirmationDialog(Text("Restore appearance, language, and aliases?", bundle: .module), isPresented: $confirmPreferences) {
                            Button { Task { await backup.restorePreferences() } } label: { Text("Restore", bundle: .module) }
                        } message: {
                            Text("This replaces appearance and language. Existing aliases and alias conflicts are kept. Library import is a separate operation.", bundle: .module)
                        }
                    }
                    statusRow(for: [.preferences])
                }
            } else {
                PrismSettingsNote(Text("This backup contains no safe preferences.", bundle: .module))
            }
        }
    }

    private func term(_ label: Text, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            label.foregroundStyle(PrismTheme.textSecondary)
            Text(verbatim: value).foregroundStyle(PrismTheme.text)
        }
    }

    // MARK: Status

    @ViewBuilder
    private func statusRow(for operations: [BackupModel.Operation]) -> some View {
        if let error = backup.error, let retry = backup.retry, operations.contains(retry) {
            HStack(alignment: .center, spacing: 10) {
                Image(systemName: "exclamationmark.triangle").foregroundStyle(PrismTheme.warning)
                Text(verbatim: L10n.tr(error)).foregroundStyle(PrismTheme.textSecondary).fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 8)
                Button { Task { await backup.runRetry() } } label: { Text(verbatim: retryTitle(retry)) }
                    .buttonStyle(.prism)
                    .disabled(backup.isBusy)
            }
            .font(.system(size: 11))
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .prismSettingsCard(cornerRadius: 10)
        } else if let status = backup.status, backup.lastOperation.map(operations.contains) ?? false {
            HStack(spacing: 7) {
                Image(systemName: "checkmark.circle").foregroundStyle(PrismTheme.textSecondary)
                Text(verbatim: status).foregroundStyle(PrismTheme.textSecondary)
            }
            .font(.system(size: 11))
        }
    }

    private func retryTitle(_ operation: BackupModel.Operation) -> String {
        switch operation {
        case .review, .apply: L10n.tr("Review File Again")
        case .backup, .export: L10n.tr("Retry Export")
        case .preferences: L10n.tr("Retry Preferences Restore")
        }
    }

    private func pathStatus(_ reference: BackupPathReference) -> String {
        let status = switch reference.status {
        case .existing: L10n.tr("Target exists")
        case .missing: L10n.tr("Target missing")
        case .unavailable: L10n.tr("Target could not be checked")
        }
        return reference.conflict ? status + " · " + L10n.tr("Existing item kept") : status
    }

    private func aliasStatus(_ alias: SafePreferencesMerge.AliasReview) -> String {
        switch alias.status {
        case .add: L10n.tr("Add alias")
        case .idConflict: L10n.tr("Existing command alias kept") + (alias.existingAlias.map { ": \($0)" } ?? "")
        case .valueConflict: L10n.tr("Alias already used; skipped")
        case .capacity: L10n.tr("Alias limit reached; skipped")
        }
    }

    private func languageName(_ value: String) -> String {
        L10n.tr(value == "ko" ? "Korean" : value == "en" ? "English" : "System")
    }

    private func themeName(_ value: String) -> String {
        L10n.tr(value == "dark" ? "Dark" : value == "light" ? "Light" : "System")
    }

    private func onOff(_ value: Bool) -> String { L10n.tr(value ? "On" : "Off") }
}
