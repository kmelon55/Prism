import AppKit
import PrismKit
import SwiftUI

@MainActor
enum TextInput {
    /// True while an input method (Korean, Japanese, …) is composing in the focused field. Return and
    /// Escape belong to the input method then.
    static var isComposing: Bool {
        (NSApp.keyWindow?.firstResponder as? NSTextView)?.hasMarkedText() ?? false
    }
}

/// Clipboard History inside the compact palette, as in the Tauri app: the search line with a back arrow, a
/// type filter row, the list beside the selected entry's preview, and the palette status bar.
struct ClipboardHistoryView: View {
    @Bindable var model: ClipboardHistoryModel
    @FocusState private var searchFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            searchBar
            typeFilter
            ZStack {
                content
                    .prismActionPanelBlur(model.isActionPanelOpen)
                if model.isActionPanelOpen, let entry = model.selectedEntry {
                    PrismActionPanel(
                        title: EntryPresentation(entry: entry).title, actions: model.actions, selection: model.actionSelection,
                        searchPrompt: ClipboardText.localize("Search actions…"), emptyText: ClipboardText.localize("No matching actions"),
                        onSelect: { index in
                            model.actionSelection = index
                            model.activate()
                        },
                        onDismiss: { model.isActionPanelOpen = false }
                    )
                }
            }
            footer
        }
        .overlay {
            if model.isConfirmingClear {
                ClearConfirmation(onCancel: { model.isConfirmingClear = false }, onConfirm: model.confirmClear)
            }
        }
        .onAppear { searchFocused = true }
        .onChange(of: model.isActionPanelOpen) { searchFocused = true }
        .task(id: ObjectIdentifier(model)) { model.load() }
        .onReceive(NotificationCenter.default.publisher(for: ClipboardHistory.didChange)) { _ in model.refresh() }
    }

    private var searchBar: some View {
        HStack(spacing: 12) {
            PrismBackButton(help: Text("Back to all commands", bundle: .module), action: model.goBack)
            TextField(text: $model.query, prompt: Text("Search Clipboard History…", bundle: .module).foregroundStyle(PrismTheme.textMuted)) {
                Text("Search clipboard history", bundle: .module)
            }
            .textFieldStyle(.plain)
            .font(.system(size: 16))
            .tracking(-0.29)
            .foregroundStyle(PrismTheme.text)
            .focused($searchFocused)
            .onKeyPress(phases: .down, action: handle)
            .onSubmit {
                // Reached only when the key handler let Return through to the input method, which then
                // committed its text and passed Return on. Acts once, never while text is marked.
                guard !TextInput.isComposing else { return }
                model.activate()
            }
            if !model.query.isEmpty {
                Button { model.query = "" } label: {
                    Text("Clear", bundle: .module)
                        .font(.prism(11, weight: 600))
                        .foregroundStyle(PrismTheme.textMuted)
                        .padding(.horizontal, 7)
                        .frame(height: 29)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.leading, 16)
        .padding(.trailing, 22)
        .frame(height: PrismPaletteMetrics.searchHeight)
    }

    /// "Clipboard type [All types ⌄]" with the capture status on the right (`.clipboard-type-filter`).
    private var typeFilter: some View {
        HStack(spacing: 10) {
            Text("Clipboard type", bundle: .module)
            Menu {
                Picker(selection: $model.filter) {
                    ForEach(ClipboardHistoryModel.Filter.allCases) { filter in
                        Text(verbatim: filter.title).tag(filter)
                    }
                } label: {
                    Text("Clipboard type", bundle: .module)
                }
                .pickerStyle(.inline)
            } label: {
                HStack(spacing: 8) {
                    Text(verbatim: model.filter.title).foregroundStyle(PrismTheme.textSecondary)
                    Image(systemName: "chevron.down").font(.system(size: 9, weight: .semibold)).foregroundStyle(PrismTheme.textMuted)
                }
                .padding(.leading, 9)
                .padding(.trailing, 8)
                .frame(height: 24)
                .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(PrismTheme.surface))
                .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous).strokeBorder(PrismTheme.line))
                .contentShape(Rectangle())
            }
            .menuStyle(.button)
            .buttonStyle(.plain)
            .menuIndicator(.hidden)
            .fixedSize()
            .help(Text("Clipboard type (⌘P)", bundle: .module))
            Spacer(minLength: 8)
            CaptureStatusLabel(settings: model.settings)
        }
        .font(.prism(12))
        .foregroundStyle(PrismTheme.textMuted)
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .overlay(alignment: .top) { PrismRule() }
        .overlay(alignment: .bottom) { PrismRule() }
    }

    private func handle(_ press: KeyPress) -> KeyPress.Result {
        let composing = TextInput.isComposing
        switch (press.key, press.modifiers) {
        case (.return, []):
            if composing { return .ignored }
            model.activate()
            return .handled
        case (.escape, _):
            return !composing && model.handleEscape() ? .handled : .ignored
        case (.downArrow, []), ("n", .control):
            model.moveSelection(by: 1)
            return .handled
        case (.upArrow, []), ("p", .control):
            model.moveSelection(by: -1)
            return .handled
        case ("k", .command):
            model.toggleActionPanel()
            return .handled
        case ("p", .command):
            model.cycleFilter()
            return .handled
        default:
            guard !composing, !press.modifiers.isEmpty, press.modifiers != .shift else { return .ignored }
            if model.isConfirmingClear { return .handled }
            return model.performShortcut(key: press.key, modifiers: press.modifiers) ? .handled : .ignored
        }
    }

    @ViewBuilder
    private var content: some View {
        if !model.hasLoaded {
            Color.clear.frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if !model.isEnabled {
            PrismEmptyState(
                title: Text("Clipboard History is off", bundle: .module),
                message: Text("Enable it in Settings → Clipboard to keep copied text on this device.", bundle: .module),
                button: (Text("Open Clipboard Settings", bundle: .module), model.openSettings)
            )
        } else if model.entries.isEmpty {
            PrismEmptyState(
                symbol: model.errorMessage == nil ? "circle.dashed" : "exclamationmark.triangle",
                title: model.errorMessage.map { Text(verbatim: $0) } ?? Text("No clipboard items", bundle: .module),
                message: model.query.isEmpty
                    ? Text("Copied text, images and files will appear here.", bundle: .module)
                    : Text("No clipboard history matches “\(model.query)”.", bundle: .module)
            )
        } else {
            GeometryReader { proxy in
                HStack(spacing: 0) {
                    list.frame(width: (proxy.size.width * 0.44).rounded())
                    PrismVerticalRule()
                    if let entry = model.selectedEntry {
                        ClipboardPreviewPane(entry: entry, store: model.store)
                            .id(entry.id)
                    } else {
                        Text("Select an entry to preview its contents.", bundle: .module)
                            .font(.prism(12))
                            .foregroundStyle(PrismTheme.textMuted)
                            .multilineTextAlignment(.center)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                }
            }
        }
    }

    private var list: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(model.sections.enumerated()), id: \.element.id) { offset, section in
                        PrismSectionLabel(section.title, isFirst: offset == 0)
                        ForEach(section.entries) { entry in
                            ClipboardRow(entry: entry, store: model.store, isSelected: entry.id == model.selectedID)
                                .id(entry.id)
                                .contentShape(Rectangle())
                                .onTapGesture(count: 2) {
                                    model.selectedID = entry.id
                                    model.activate()
                                }
                                .onTapGesture { model.selectedID = entry.id }
                        }
                    }
                }
                .padding(.horizontal, 12)
                .padding(.top, 5)
                .padding(.bottom, 10)
            }
            .scrollIndicators(.never)
            .onChange(of: model.selectedID) { _, id in
                guard let id else { return }
                proxy.scrollTo(id)
            }
        }
    }

    private var footer: some View {
        PrismStatusBar {
            PrismStatusButton(action: model.openSettings) {
                Image(systemName: "gearshape").font(.system(size: 13, weight: .light))
            }
            .help(Text("Open Clipboard Settings", bundle: .module))
        } trailing: {
            if let primary = model.actions.first {
                PrismStatusAction(Text(verbatim: primary.title), keys: "↵", isPrimary: true) { model.activate() }
                    .disabled(model.isActionPanelOpen)
                PrismStatusDivider()
                PrismStatusAction(Text("Actions", bundle: .module), keys: "⌘K", isActive: model.isActionPanelOpen) {
                    model.toggleActionPanel()
                }
            }
        }
    }
}

/// The capture state on the right of the type filter (`.clipboard-capture-status`).
private struct CaptureStatusLabel: View {
    let settings: ClipboardSettingsState?

    var body: some View {
        if let settings {
            Text(verbatim: title(settings))
                .font(.prism(11))
                .foregroundStyle(PrismTheme.textMuted)
                .lineLimit(1)
        }
    }

    private func title(_ settings: ClipboardSettingsState) -> String {
        guard settings.enabled else { return ClipboardText.localize("History is off") }
        return ClipboardText.localize(settings.isPaused ? "Recording paused" : "Recording clipboard changes")
    }
}

/// A two-line history row (`.clipboard-workspace .result-row`): glyph, one-line title, then kind and time.
struct ClipboardRow: View {
    let entry: ClipboardEntry
    let store: ClipboardStore
    let isSelected: Bool

    var body: some View {
        let presentation = EntryPresentation(entry: entry)
        HStack(spacing: 10) {
            RowIcon(entry: entry, style: presentation.style, store: store, isSelected: isSelected)
                .frame(width: 26, height: 26)
            VStack(alignment: .leading, spacing: 5) {
                Text(verbatim: presentation.title)
                    .font(.prism(13, weight: 550))
                    .tracking(-0.065)
                    .foregroundStyle(PrismTheme.text)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Text(verbatim: "\(presentation.kindTitle) · \(ClipboardFormat.relative(entry.capturedAt))")
                    .font(.prism(10))
                    .foregroundStyle(PrismTheme.textMuted)
                    .lineLimit(1)
            }
            Spacer(minLength: 6)
            if entry.pinned {
                Image(systemName: "pin")
                    .font(.system(size: 10))
                    .foregroundStyle(PrismTheme.textMuted)
                    .accessibilityLabel(Text("Pinned", bundle: .module))
            }
        }
        .padding(.horizontal, 11)
        .frame(minHeight: 60)
        .prismRowBackground(isSelected: isSelected)
    }
}

private struct RowIcon: View {
    let entry: ClipboardEntry
    let style: EntryPresentation.Style
    let store: ClipboardStore
    var isSelected = false
    @ViewState private var thumbnail: NSImage?

    var body: some View {
        switch style {
        case .image:
            Group {
                if let image = thumbnail ?? ThumbnailLoader.shared.cached(id: entry.id, maxPixelSize: 64) {
                    Image(nsImage: image)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                        .frame(width: 24, height: 24)
                        .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
                } else {
                    symbol("photo")
                }
            }
            .task(id: entry.id) {
                thumbnail = await ThumbnailLoader.shared.image(id: entry.id, maxPixelSize: 64, store: store)
            }
        case .files(let paths):
            if let path = paths.first {
                Image(nsImage: AppIconCache.shared.icon(forPath: path)).resizable()
            } else {
                symbol("doc")
            }
        case .color(let color):
            RoundedRectangle(cornerRadius: 5, style: .continuous)
                .fill(Color(nsColor: color))
                .overlay(RoundedRectangle(cornerRadius: 5, style: .continuous).strokeBorder(PrismTheme.lineStrong))
                .padding(4)
        case .link:
            symbol("link")
        case .text:
            symbol("text.alignleft")
        }
    }

    private func symbol(_ name: String) -> some View {
        Image(systemName: name)
            .font(.system(size: 15, weight: .light))
            .foregroundStyle(isSelected ? PrismTheme.accentStrong : PrismTheme.textSecondary)
    }
}

private struct ClearConfirmation: View {
    let onCancel: () -> Void
    let onConfirm: () -> Void

    var body: some View {
        ZStack {
            Color.black.opacity(0.34)
                .contentShape(Rectangle())
                .onTapGesture(perform: onCancel)
            VStack(alignment: .leading, spacing: 10) {
                Text("Delete all clipboard history?", bundle: .module)
                    .font(.prism(13, weight: 600))
                    .foregroundStyle(PrismTheme.text)
                Text("Permanently delete all clipboard entries, including pins? History will stay enabled if it is on.", bundle: .module)
                    .font(.prism(12))
                    .foregroundStyle(PrismTheme.textSecondary)
                    .lineSpacing(2)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 8) {
                    Spacer()
                    Button(action: onCancel) {
                        HStack(spacing: 6) { Text("Cancel", bundle: .module); KeyCap("esc") }
                    }
                    .buttonStyle(.prism)
                    Button(action: onConfirm) {
                        HStack(spacing: 6) { Text("Delete All", bundle: .module); KeyCap("↵") }
                    }
                    .buttonStyle(.prismDestructive)
                }
                .padding(.top, 6)
            }
            .padding(15)
            .frame(width: 360)
            .background(PrismTheme.panel, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(PrismTheme.lineStrong))
            .shadow(color: .black.opacity(0.2), radius: 32, y: 12)
        }
    }
}
