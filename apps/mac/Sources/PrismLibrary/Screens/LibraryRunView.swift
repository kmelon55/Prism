import Observation
import PrismKit
import SwiftUI

/// The argument prompt and preview for quicklinks with `{query}` and snippets with date, time or clipboard
/// placeholders. What the preview shows is exactly what runs.
@MainActor
@Observable
final class LibraryRunModel {
    private(set) var entry: LibraryEntry
    let action: LibraryRunner.Action
    var query = "" { didSet { if query != oldValue { refresh() } } }
    private(set) var preview: String?
    private(set) var error: String?
    private(set) var isRunning = false
    @ObservationIgnored private let services: LibraryServices
    /// Leaves the preview after a copy that keeps the palette open.
    @ObservationIgnored var onFinished: (() -> Void)?

    init(entry: LibraryEntry, action: LibraryRunner.Action, services: LibraryServices) {
        self.entry = entry
        self.action = action
        self.services = services
        refresh()
    }

    var needsQuery: Bool { entry.needsQuery }

    func refresh() {
        error = nil
        preview = nil
        if needsQuery && query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return }
        do {
            preview = try services.runner.prepare(entry, query: needsQuery ? query : nil)
        } catch {
            self.error = error.localizedDescription
        }
    }

    func run() async {
        guard let preview, !isRunning else { return }
        isRunning = true
        defer { isRunning = false }
        switch await services.runner.run(entry, value: preview, action: action) {
        case .success(let outcome):
            services.apply(outcome)
            if case .notify = outcome { onFinished?() }
        case .failure(let failure):
            // Start again from the saved entry; never run a preview the user has not seen.
            if let current = services.model.entry(id: entry.id) { entry = current }
            refresh()
            error = failure.localizedDescription
        }
    }
}

struct LibraryRunView: View {
    @Bindable var model: LibraryRunModel
    var onBack: (() -> Void)?
    @FocusState private var focus: Field?

    private enum Field { case query, body }

    var body: some View {
        VStack(spacing: 0) {
            ScreenHeader(onBack: onBack) {
                if model.needsQuery {
                    HStack(spacing: 9) {
                        PrismSearchGlyph()
                        TextField(text: $model.query, prompt: Text("Query", bundle: .module).foregroundStyle(PrismTheme.textMuted)) {
                            Text("Query", bundle: .module)
                        }
                        .textFieldStyle(.plain)
                        .font(.prism(14))
                        .foregroundStyle(PrismTheme.text)
                        .focused($focus, equals: .query)
                        .onSubmit { submit() }
                    }
                } else {
                    Text(verbatim: model.entry.title)
                        .font(.prism(15, weight: 550))
                        .foregroundStyle(PrismTheme.text)
                        .lineLimit(1)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            } trailing: {
                Text(verbatim: model.entry.title)
                    .font(.prism(11, weight: 500))
                    .foregroundStyle(PrismTheme.textSecondary)
                    .padding(.horizontal, 8)
                    .frame(height: 22)
                    .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(PrismTheme.surfaceStrong))
                    .lineLimit(1)
                    .opacity(model.needsQuery ? 1 : 0)
            }
            content
            PrismStatusBar {
                Text("Execution preview", bundle: .module)
                    .foregroundStyle(PrismTheme.textMuted)
                    .padding(.horizontal, 7)
            } trailing: {
                PrismStatusAction(Text("Refresh Preview", bundle: .module), keys: "⌘R") { model.refresh() }
                    .keyboardShortcut("r", modifiers: .command)
                PrismStatusDivider()
                PrismStatusAction(Text(verbatim: model.action.title), keys: "↵", isPrimary: true) { submit() }
                    .disabled(model.preview == nil || model.isRunning)
            }
        }
        .focusable(!model.needsQuery)
        .focused($focus, equals: .body)
        .focusEffectDisabled()
        .onKeyPress(.return) {
            guard focus == .body else { return .ignored }
            submit()
            return .handled
        }
        .onAppear { focus = model.needsQuery ? .query : .body }
    }

    /// `.library-run-preview`: exactly what runs, in an inset well.
    @ViewBuilder
    private var content: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                if let preview = model.preview {
                    Text(verbatim: preview)
                        .font(.system(size: 11.5, design: .monospaced))
                        .foregroundStyle(PrismTheme.textSecondary)
                        .lineSpacing(5)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(17)
                        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.black.opacity(0.03)))
                        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(PrismTheme.line))
                } else if model.needsQuery && model.error == nil {
                    Text("Type a search term to fill in {query}.", bundle: .module)
                        .font(.prism(12))
                        .foregroundStyle(PrismTheme.textMuted)
                        .padding(.top, 4)
                }
                if let error = model.error {
                    Text(verbatim: error)
                        .font(.prism(12))
                        .foregroundStyle(PrismTheme.danger)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(25)
        }
        .scrollIndicators(.never)
        .frame(maxHeight: .infinity)
    }

    private func submit() {
        guard !TextInputState.isComposing else { return }
        Task { await model.run() }
    }
}

/// "Delete this entry?" as a palette screen for the root ⌃X action.
struct DeleteConfirmationView: View {
    let entry: LibraryEntry
    var onCancel: (() -> Void)?
    var onConfirm: () async -> Void
    @FocusState private var focused: Bool
    private let state = DeleteState()

    var body: some View {
        VStack(spacing: 0) {
            ScreenHeader(onBack: onCancel) {
                Text("Delete Entry", bundle: .module)
                    .font(.prism(15, weight: 550))
                    .foregroundStyle(PrismTheme.text)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } trailing: { EmptyView() }
            VStack(spacing: 8) {
                LibraryIconView(icon: LibraryProvider.icon(for: entry)).frame(width: 26, height: 26)
                Text(verbatim: String(format: L10n.tr("Delete “%@”?"), entry.title))
                    .font(.prism(12.5, weight: 600))
                    .foregroundStyle(PrismTheme.textSecondary)
                    .multilineTextAlignment(.center)
                    .padding(.top, 6)
                Text("This can’t be undone.", bundle: .module)
                    .font(.prism(12, weight: 500))
                    .foregroundStyle(PrismTheme.textMuted)
            }
            .padding(24)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            PrismStatusBar {
                EmptyView()
            } trailing: {
                PrismStatusAction(Text("Cancel", bundle: .module), keys: "esc") { onCancel?() }
                PrismStatusDivider()
                PrismStatusButton(tint: PrismTheme.danger, action: confirm) {
                    HStack(spacing: 6) {
                        Text(verbatim: L10n.tr("Delete"))
                        PrismShortcutCaps("↵")
                    }
                }
            }
        }
        .focusable()
        .focused($focused)
        .focusEffectDisabled()
        .onKeyPress(.return) {
            confirm()
            return .handled
        }
        .onAppear { focused = true }
    }

    private func confirm() {
        guard !state.isDeleting else { return }
        state.isDeleting = true
        Task { await onConfirm() }
    }
}

@MainActor
private final class DeleteState {
    var isDeleting = false
}
