import AppKit
import PrismAI
import PrismCore
import PrismKit
import SwiftUI

/// The launcher, styled after the Tauri app's neutral glass: a quiet search line with the Prism mark,
/// monochrome rows with inline subtitles, and a slim status bar.
struct PaletteView: View {
    static let size = CGSize(width: 760, height: 500)
    static let expandedSize = CGSize(width: 1080, height: 760)

    @Bindable var model: PaletteModel
    var onOpenSettings: () -> Void

    @FocusState private var searchFocused: Bool

    var body: some View {
        Group {
            if let screen = model.screens.last {
                screen.content()
                    .id(screen.id)
            } else {
                root
            }
        }
        // Fills the panel, which grows into the 1080×760 workspace for expanded screens.
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .overlay { PrismShellOverlay() }
    }

    private var root: some View {
        VStack(spacing: 0) {
            searchField
            ZStack {
                results
                    .prismActionPanelBlur(model.actionPanelItem != nil)
                if let item = model.actionPanelItem {
                    PrismActionPanel(
                        title: item.title, actions: model.actionPanelActions, selection: model.actionSelection,
                        query: $model.actionQuery, onMove: { model.moveSelection(by: $0) },
                        onSelect: { index in
                            model.actionSelection = index
                            model.activate()
                        },
                        onDismiss: { model.closeActionPanel() }
                    )
                }
            }
            footer
        }
        .onAppear { searchFocused = true }
        .onChange(of: model.focusToken) { searchFocused = true }
        .onChange(of: model.query) { model.refresh() }
    }

    private var searchField: some View {
        HStack(spacing: 12) {
            PrismMark()
                .frame(width: 25, height: 25)
            TextField(text: $model.query, prompt: Text("Search apps, commands and files…", bundle: .module).foregroundStyle(PrismTheme.textMuted)) {
                Text("Search apps, commands and files…", bundle: .module)
            }
            .textFieldStyle(.plain)
            .font(.system(size: 16))
            .tracking(-0.29)
            .foregroundStyle(PrismTheme.text)
            .focused($searchFocused)
            .onSubmit { model.activate() }
            .onKeyPress(.downArrow) { model.moveSelection(by: 1); return .handled }
            .onKeyPress(.upArrow) { model.moveSelection(by: -1); return .handled }
            .onKeyPress(phases: .down) { press in handle(press) }
            HStack(spacing: 6) {
                // Tab also opens AI with the query, as in the Tauri app; the pill shows only the mark.
                ToolbarPill(bordered: true) {
                    model.runPublishedCommand(id: AIFeature.chatCommandID)
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "sparkles").font(.system(size: 13, weight: .regular))
                        Text(verbatim: "AI")
                    }
                }
                .help(Text("Open AI Chat", bundle: .module))
                if !model.query.isEmpty {
                    ToolbarPill { model.query = "" } label: { Text("Clear", bundle: .module) }
                        .help(Text("Clear search", bundle: .module))
                }
            }
        }
        .padding(.horizontal, 22)
        .frame(height: PrismPaletteMetrics.searchHeight)
    }

    private func handle(_ press: KeyPress) -> KeyPress.Result {
        if press.modifiers == .control, press.key == "n" || press.key == "p" {
            model.moveSelection(by: press.key == "n" ? 1 : -1)
            return .handled
        }
        // Tab asks AI about the query, like the Tauri app. Never while an input method is composing.
        if press.key == .tab, press.modifiers.isEmpty, !Self.isComposingText {
            return model.runPublishedCommand(id: AIFeature.chatCommandID) ? .handled : .ignored
        }
        if press.modifiers == .command, press.key == "k" {
            model.toggleActionPanel()
            return .handled
        }
        guard !press.modifiers.isEmpty, press.modifiers != .shift else { return .ignored }
        return model.performShortcut(key: press.key, modifiers: press.modifiers) ? .handled : .ignored
    }

    private static var isComposingText: Bool {
        (NSApp.keyWindow?.firstResponder as? NSTextView)?.hasMarkedText() == true
    }

    @ViewBuilder
    private var results: some View {
        if model.results.isEmpty {
            if model.hasPendingProviders {
                PrismLoadingRows()
                    .padding(.horizontal, 12)
                    .accessibilityLabel(Text("Searching…", bundle: .module))
            } else {
                PrismEmptyState(
                    title: Text("No results", bundle: .module),
                    message: Text("Nothing matches “\(model.query)”. Try an app, action, or setting.", bundle: .module)
                )
                .padding(.bottom, 20)
            }
        } else {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(Array(model.sections.enumerated()), id: \.element.id) { offset, section in
                            PrismSectionLabel(section.title, isFirst: offset == 0)
                            ForEach(section.rows) { row in
                                PaletteRow(item: row.item, isSelected: row.index == model.selection)
                                    .id(row.id)
                                    .contentShape(Rectangle())
                                    .onTapGesture { model.activate(index: row.index) }
                            }
                        }
                    }
                    .padding(.horizontal, 12)
                    .padding(.top, 5)
                    .padding(.bottom, 10)
                }
                .scrollIndicators(.never)
                .onChange(of: model.selection) { _, selection in
                    guard model.results.indices.contains(selection) else { return }
                    proxy.scrollTo(model.results[selection].id)
                }
            }
        }
    }

    private var footer: some View {
        PrismStatusBar {
            PrismStatusButton(action: onOpenSettings) {
                Image(systemName: "gearshape").font(.system(size: 13, weight: .light))
            }
            .keyboardShortcut(",", modifiers: .command)
            .help(Text("Settings", bundle: .module))
        } trailing: {
            if let primary = model.selectedItem?.actions.first {
                PrismStatusAction(Text(verbatim: primary.title), keys: "↵", isPrimary: true) { model.activate() }
                    .disabled(model.actionPanelItem != nil)
                PrismStatusDivider()
            }
            PrismStatusAction(Text("Actions", bundle: .module), keys: "⌘K", isActive: model.actionPanelItem != nil) {
                model.toggleActionPanel()
            }
            .disabled(model.selectedItem == nil)
        }
    }
}

struct PaletteRow: View {
    let item: PaletteItem
    let isSelected: Bool

    var body: some View {
        HStack(spacing: 10) {
            PaletteIconView(icon: item.icon, isSelected: isSelected)
                .frame(width: 26, height: 26)
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text(verbatim: item.title)
                    .font(.prism(13, weight: 550))
                    .tracking(-0.065)
                    .foregroundStyle(PrismTheme.text)
                    .lineLimit(1)
                    .layoutPriority(1)
                if !item.subtitle.isEmpty {
                    Text(verbatim: item.subtitle)
                        .font(.system(size: 11))
                        .foregroundStyle(PrismTheme.textMuted)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 12)
            if item.candidate.favoriteOrder != nil {
                Image(systemName: "star")
                    .font(.system(size: 10))
                    .foregroundStyle(PrismTheme.textMuted.opacity(0.7))
            }
            // Answers keep their short context (rate source, unit family); other rows stay clean like Tauri.
            if item.candidate.matchedQuery != nil, !item.accessory.isEmpty {
                Text(verbatim: item.accessory)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(PrismTheme.textMuted)
                    .lineLimit(1)
            }
        }
        .padding(.horizontal, 11)
        .frame(minHeight: PrismPaletteMetrics.rowHeight)
        .prismRowBackground(isSelected: isSelected)
    }
}

struct PaletteIconView: View {
    let icon: PaletteIcon
    var isSelected = false
    @AppStorage(PreferenceKey.showApplicationIcons) private var showFileIcons = true

    var body: some View {
        switch icon {
        case .symbol(let name, _):
            // Monochrome line glyphs like the Tauri lucide icons; module tints are intentionally ignored here.
            Image(systemName: PrismGlyph.outline(name))
                .font(.system(size: 15, weight: .light))
                .foregroundStyle(isSelected ? PrismTheme.accentStrong : PrismTheme.textSecondary)
        case .file(let path):
            if showFileIcons {
                Image(nsImage: AppIconCache.shared.icon(forPath: path)).resizable()
            } else {
                Image(systemName: "app").font(.system(size: 15, weight: .light)).foregroundStyle(PrismTheme.textSecondary)
            }
        case .image(let image):
            Image(nsImage: image).resizable().aspectRatio(contentMode: .fit)
        case .text(let text):
            Text(verbatim: text).font(.system(size: 18))
        case .none:
            Color.clear
        }
    }
}

/// A small control in the search line: the bordered "AI" pill (`.ai-icon-button`) and the "Clear" text button.
private struct ToolbarPill<Label: View>: View {
    var bordered = false
    let action: () -> Void
    @ViewBuilder let label: () -> Label
    @ViewState private var hovering = false

    var body: some View {
        Button(action: action) {
            label()
                .font(.prism(11, weight: 600))
                .foregroundStyle(hovering ? PrismTheme.text : (bordered ? PrismTheme.accentStrong : PrismTheme.textMuted))
                .padding(.horizontal, bordered ? 9 : 7)
                .frame(height: 29)
                .background {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(hovering ? PrismTheme.surfaceStrong : (bordered ? PrismTheme.surfaceSelected : Color.clear))
                }
                .overlay {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .strokeBorder(bordered ? (hovering ? PrismTheme.lineStrong : PrismTheme.accent.opacity(0.15)) : Color.clear)
                }
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}
