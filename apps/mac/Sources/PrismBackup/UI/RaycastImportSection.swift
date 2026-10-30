import PrismKit
import SwiftUI

/// `RaycastImport.tsx`: a heading with the arrow tile, the file chooser, the password field, the import preview
/// and, after an import, the recovery card.
struct RaycastImportSection: View {
    @Bindable var model: RaycastImportModel

    @ViewState private var confirmImport = false
    @ViewState private var confirmDiscard = false
    @FocusState private var passwordFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            heading
            if let journal = model.journal {
                recovery(journal)
            } else {
                choose
                if let rows = model.rows { preview(rows) }
            }
            errorRow
        }
        .onAppear { if !model.journalLoaded { model.loadJournal() } }
    }

    // MARK: Choose

    private var heading: some View {
        HStack(spacing: 12) {
            Image(systemName: "arrow.right")
                .font(.system(size: 17, weight: .medium))
                .foregroundStyle(PrismTheme.text)
                .frame(width: 40, height: 40)
                .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(PrismTheme.surfaceSelected))
                .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(PrismTheme.lineStrong))
            VStack(alignment: .leading, spacing: 7) {
                Text("Bring your Raycast setup", bundle: .module)
                    .font(.system(size: 15, weight: .semibold))
                    .tracking(-0.3)
                    .foregroundStyle(PrismTheme.text)
                Text("Your shortcuts, snippets, and quicklinks. Ready for Prism.", bundle: .module)
                    .font(.system(size: 12))
                    .foregroundStyle(PrismTheme.textSecondary)
            }
        }
    }

    private var choose: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                if let file = model.fileURL {
                    Text(verbatim: file.lastPathComponent)
                        .font(.system(size: 12)).foregroundStyle(PrismTheme.textSecondary)
                        .lineLimit(1).truncationMode(.middle)
                }
                Spacer(minLength: 0)
                if model.busy && model.rows == nil { ProgressView().controlSize(.small) }
                Button { Task { await model.chooseFile() } } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "doc.badge.arrow.up").font(.system(size: 11))
                        Text("Choose Raycast export", bundle: .module)
                    }
                }
                .buttonStyle(.prismPrimary)
                .disabled(model.busy || !model.journalLoaded)
            }
            if model.needsPassword {
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 8) {
                        SecureField(text: $model.password, prompt: Text("Export password", bundle: .module)) {
                            Text("Export password", bundle: .module)
                        }
                        .labelsHidden()
                        .textFieldStyle(PrismTextFieldStyle(height: 34))
                        .focused($passwordFocused)
                        .onSubmit { Task { await model.unlock() } }
                        if model.busy { ProgressView().controlSize(.small) }
                        Button { Task { await model.unlock() } } label: { Text("Unlock", bundle: .module) }
                            .buttonStyle(.prism)
                            .disabled(model.busy || model.password.isEmpty)
                    }
                    PrismSettingsNote(Text("This export is encrypted.", bundle: .module)
                        + Text(verbatim: " ")
                        + Text("The password is used only to decode the file on this Mac and is never saved.", bundle: .module))
                }
                .padding(.vertical, 2)
                .onAppear { passwordFocused = true }
            }
            if model.fileURL == nil {
                PrismDisclosure(Text("How to export from Raycast", bundle: .module)) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("1. Run Export Settings & Data in Raycast.", bundle: .module)
                        Text("2. Save the .rayconfig file and remember its export password.", bundle: .module)
                        Text("3. Choose the file here, then review what to bring over.", bundle: .module)
                    }
                    .font(.system(size: 12))
                    .lineSpacing(4)
                    .foregroundStyle(PrismTheme.textSecondary)
                    .padding(.leading, 15)
                }
            }
        }
    }

    // MARK: Preview

    private func preview(_ rows: [ImportItem]) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 16) {
                summary(model.ready, "Ready")
                summary(model.conflicts, "Conflicts")
                summary(model.unsupported, "Unsupported")
            }
            .padding(.top, 6)
            VStack(alignment: .leading, spacing: 10) {
                Text("Bring over", bundle: .module).font(.system(size: 12, weight: .semibold)).foregroundStyle(PrismTheme.text)
                PrismFlowLayout(horizontalSpacing: 20, verticalSpacing: 10) {
                    ForEach(ImportItem.Category.allCases, id: \.self) { category in
                        Toggle(isOn: Binding(get: { model.isCategorySelected(category) }, set: { model.setCategory(category, selected: $0) })) {
                            Text(verbatim: categoryName(category))
                        }
                        .disabled(model.busy || model.candidates(in: category).isEmpty)
                    }
                }
                .toggleStyle(.prismLeadingCheckbox)
            }
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(rows) { row in
                        previewRow(row)
                        if row.id != rows.last?.id { Rectangle().fill(PrismTheme.separator).frame(height: 1) }
                    }
                }
            }
            .frame(height: min(CGFloat(rows.count) * 50, 290))
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(PrismTheme.lineStrong))
            .accessibilityLabel(Text("Import preview", bundle: .module))
            HStack(spacing: 8) {
                Spacer(minLength: 0)
                Button { model.cancel() } label: { Text("Cancel", bundle: .module) }
                    .buttonStyle(.prism)
                    .keyboardShortcut(.cancelAction)
                    .disabled(model.busy)
                Button { confirmImport = true } label: { Text("Import \(model.selected.count) Items", bundle: .module) }
                    .buttonStyle(.prismPrimary)
                    .disabled(model.busy || model.selected.isEmpty)
                    .confirmationDialog(Text("Import \(model.selected.count) items from Raycast?", bundle: .module), isPresented: $confirmImport) {
                        Button { Task { await model.apply() } } label: { Text("Import", bundle: .module) }
                    } message: {
                        Text("Existing settings stay unless you select a replacement. You can undo the import afterwards.", bundle: .module)
                    }
            }
            PrismSettingsNote(Text("A local recovery copy is saved before import. Quit Raycast before activating the same hotkeys.", bundle: .module)
                + Text(verbatim: " ")
                + Text("Existing settings stay unless you select a replacement. Unsupported items are skipped.", bundle: .module))
        }
    }

    /// `.raycast-summary`: a 17 pt count followed by its label.
    private func summary(_ count: Int, _ title: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 5) {
            Text(verbatim: "\(count)").font(.system(size: 17, weight: .semibold)).monospacedDigit().foregroundStyle(PrismTheme.text)
            Text(verbatim: L10n.tr(title)).font(.system(size: 12)).foregroundStyle(PrismTheme.textSecondary)
        }
    }

    /// `.raycast-review-row`: checkbox, title over category and value, and the outcome on the right.
    private func previewRow(_ row: ImportItem) -> some View {
        let isSelected = model.selected.contains(row.id)
        return HStack(spacing: 10) {
            Toggle(isOn: Binding(get: { isSelected }, set: { _ in model.toggle(row) })) { EmptyView() }
                .toggleStyle(.prismLeadingCheckbox)
                .labelsHidden()
                .disabled(model.busy || !model.isSelectable(row))
            Image(systemName: icon(row.category))
                .font(.system(size: 11))
                .frame(width: 16)
                .foregroundStyle(PrismTheme.textMuted)
            VStack(alignment: .leading, spacing: 4) {
                Text(verbatim: row.title).font(.system(size: 12, weight: .medium)).foregroundStyle(PrismTheme.text).lineLimit(1)
                Text(verbatim: detail(row)).font(.system(size: 10)).foregroundStyle(PrismTheme.textMuted).lineLimit(1).truncationMode(.middle)
            }
            Spacer(minLength: 8)
            Text(verbatim: status(row, selected: isSelected))
                .font(.system(size: 11))
                .foregroundStyle(row.reason != nil ? PrismTheme.textMuted : row.conflict == true ? PrismTheme.warning : PrismTheme.textSecondary)
                .multilineTextAlignment(.trailing)
                .frame(maxWidth: 170, alignment: .trailing)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .contentShape(Rectangle())
        .onTapGesture { if !model.busy { model.toggle(row) } }
        .opacity(row.reason == nil ? 1 : 0.7)
    }

    private func detail(_ row: ImportItem) -> String {
        var parts = [categoryName(row.category)]
        switch row.category {
        case .hotkeys where !row.value.isEmpty:
            parts.append(RaycastPlan.shortcut(row.value)?.displayName ?? row.value)
            if let before = row.before, row.conflict == true { parts.append(L10n.format("now %@", RaycastPlan.shortcut(before)?.displayName ?? before)) }
        case .aliases:
            parts.append(row.value)
            if let before = row.before, row.conflict == true { parts.append(L10n.format("now %@", before)) }
        case .snippets, .quicklinks:
            parts.append(row.value.replacingOccurrences(of: "\n", with: " "))
            if let keyword = row.entry?.keyword { parts.append(keyword) }
        default:
            break
        }
        return parts.joined(separator: " · ")
    }

    private func status(_ row: ImportItem, selected: Bool) -> String {
        if let reason = row.reason { return L10n.tr(reason) }
        if row.conflict == true {
            return row.commandId == nil ? L10n.tr("Already in library") : L10n.tr(selected ? "Replace existing setting" : "Keep existing")
        }
        return L10n.tr("Add")
    }

    // MARK: Recovery

    /// `.raycast-recovery`: the result of the last import with undo and discard.
    private func recovery(_ journal: MigrationJournal) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Import recovery", bundle: .module).font(.system(size: 12, weight: .semibold)).foregroundStyle(PrismTheme.text)
                Spacer()
                Text("\(journal.applied) imported · \(journal.failed) failed · \(journal.undone) undone", bundle: .module)
                    .font(.system(size: 11)).foregroundStyle(PrismTheme.textSecondary)
            }
            if journal.isInterrupted {
                HStack(spacing: 7) {
                    Image(systemName: "exclamationmark.triangle").foregroundStyle(PrismTheme.warning)
                    Text("An import was interrupted. Undo can recover changes already written.", bundle: .module).foregroundStyle(PrismTheme.textSecondary)
                }
                .font(.system(size: 11))
            }
            PrismDisclosure(Text("View results", bundle: .module)) {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(journal.changes, id: \.item.id) { change in
                        HStack(alignment: .firstTextBaseline) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(verbatim: change.item.title).font(.system(size: 12)).foregroundStyle(PrismTheme.text)
                                Text(verbatim: categoryName(change.item.category)).font(.system(size: 10)).foregroundStyle(PrismTheme.textMuted)
                            }
                            Spacer()
                            Text(verbatim: change.error.map(L10n.tr) ?? stateName(change.state))
                                .font(.system(size: 11))
                                .foregroundStyle(change.state == .failed || change.error != nil ? PrismTheme.warning : PrismTheme.textSecondary)
                        }
                    }
                }
                .padding(.leading, 15)
            }
            HStack(spacing: 8) {
                if model.busy { ProgressView().controlSize(.small) }
                Spacer()
                Button { confirmDiscard = true } label: { Text("Discard Recovery…", bundle: .module) }
                    .buttonStyle(.prismDestructive)
                    .disabled(model.busy)
                    .confirmationDialog(Text("Discard the import recovery copy?", bundle: .module), isPresented: $confirmDiscard) {
                        Button(role: .destructive) { Task { await model.discardRecovery() } } label: { Text("Discard Recovery", bundle: .module) }
                    } message: {
                        Text("Imported items stay. You will no longer be able to undo this import.", bundle: .module)
                    }
                Button { Task { await model.undo() } } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "arrow.counterclockwise").font(.system(size: 11))
                        Text("Undo Import", bundle: .module)
                    }
                }
                .buttonStyle(.prism)
                .disabled(model.busy || !journal.canUndo)
            }
            PrismSettingsNote(Text("Undo keeps anything you changed after importing.", bundle: .module))
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(PrismTheme.surfaceSelected.opacity(0.5)))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(PrismTheme.lineStrong))
    }

    @ViewBuilder
    private var errorRow: some View {
        if let error = model.error {
            HStack(spacing: 8) {
                Image(systemName: "exclamationmark.triangle").foregroundStyle(PrismTheme.warning)
                Text(verbatim: L10n.tr(error)).foregroundStyle(PrismTheme.textSecondary).fixedSize(horizontal: false, vertical: true)
            }
            .font(.system(size: 11))
        }
    }

    private func categoryName(_ category: ImportItem.Category) -> String {
        switch category {
        case .hotkeys: L10n.tr("Hotkeys")
        case .aliases: L10n.tr("Aliases")
        case .snippets: L10n.tr("Snippets")
        case .quicklinks: L10n.tr("Quicklinks")
        }
    }

    private func icon(_ category: ImportItem.Category) -> String {
        switch category {
        case .hotkeys: "command"
        case .aliases: "character.cursor.ibeam"
        case .snippets: "text.quote"
        case .quicklinks: "link"
        }
    }

    private func stateName(_ state: MigrationJournal.Change.State) -> String {
        switch state {
        case .pending: L10n.tr("Pending")
        case .applied: L10n.tr("Imported")
        case .failed: L10n.tr("Failed")
        case .undone: L10n.tr("Undone")
        }
    }
}
