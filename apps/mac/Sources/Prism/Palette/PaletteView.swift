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
                            ForEach(PaletteRowBlock.blocks(section.rows)) { block in
                                switch block {
                                case .single(let row):
                                    selectable(row) {
                                        if case .answer(let answer) = row.item.style {
                                            PaletteAnswerCard(answer: answer, isSelected: row.id == model.selectedItem?.id)
                                        } else {
                                            PaletteRow(item: row.item, isSelected: row.id == model.selectedItem?.id)
                                        }
                                    }
                                case .cells(let rows):
                                    PaletteAnswerGrid(rows: rows) { row in
                                        selectable(row) {
                                            if case .answerCell(let answer) = row.item.style {
                                                PaletteAnswerCell(answer: answer, isSelected: row.id == model.selectedItem?.id)
                                            }
                                        }
                                    }
                                }
                            }
                        }
                    }
                    .backgroundPreferenceValue(PaletteRowBounds.self) { anchors in
                        GeometryReader { geometry in
                            ListSelectionSurface(rows: anchors.mapValues { geometry[$0] }, selectedID: model.selectedItem?.id,
                                                 enabled: model.actionPanelItem == nil) { model.selectFromPointer(id: $0) }
                        }
                    }
                    .padding(.horizontal, 12)
                    .padding(.top, 5)
                    .padding(.bottom, 10)
                }
                .scrollIndicators(.never)
                .onChange(of: model.selection) { _, selection in
                    guard !model.selectionFollowsPointer, model.results.indices.contains(selection) else { return }
                    proxy.scrollTo(model.results[selection].id)
                }
            }
        }
    }

    private func selectable<Content: View>(_ row: PaletteModel.Section.Row, @ViewBuilder content: () -> Content) -> some View {
        content()
            .id(row.id)
            .contentShape(Rectangle())
            .onTapGesture { model.activate(id: row.id) }
            .anchorPreference(key: PaletteRowBounds.self, value: .bounds) { [row.id: $0] }
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
    }
}

/// Consecutive answer cells share one grid; every other row stands alone.
enum PaletteRowBlock: Identifiable {
    case single(PaletteModel.Section.Row)
    case cells([PaletteModel.Section.Row])

    var id: String {
        switch self {
        case .single(let row): row.id
        case .cells(let rows): "cells:" + (rows.first?.id ?? "")
        }
    }

    static func blocks(_ rows: [PaletteModel.Section.Row]) -> [PaletteRowBlock] {
        var blocks: [PaletteRowBlock] = []
        for row in rows {
            guard case .answerCell = row.item.style else { blocks.append(.single(row)); continue }
            if case .cells(let previous) = blocks.last {
                blocks[blocks.count - 1] = .cells(previous + [row])
            } else {
                blocks.append(.cells([row]))
            }
        }
        return blocks
    }
}

/// An instant answer as a large `input → output` card, like Raycast's calculator.
struct PaletteAnswerCard: View {
    let answer: PaletteAnswer
    let isSelected: Bool

    var body: some View {
        HStack(spacing: 0) {
            side(answer.input, answer.inputDetail, emphasized: false, reservesDetail: !answer.outputDetail.isEmpty)
            Image(systemName: "arrow.right")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(PrismTheme.textMuted)
                .frame(width: 28, height: 28)
                .background(Circle().fill(PrismTheme.surfaceStrong))
                .overlay(Circle().strokeBorder(PrismTheme.line))
            side(answer.output, answer.outputDetail, emphasized: true, reservesDetail: !answer.inputDetail.isEmpty)
        }
        .frame(height: 108)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(isSelected ? PrismTheme.surfaceStrong : PrismTheme.surface))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(isSelected ? PrismTheme.lineStrong : PrismTheme.line))
        .padding(.vertical, 4)
        .accessibilityElement(children: .combine)
    }

    /// `reservesDetail` keeps both values on one line when only the other side has a detail.
    private func side(_ value: String, _ detail: String, emphasized: Bool, reservesDetail: Bool) -> some View {
        VStack(spacing: 9) {
            Text(verbatim: value)
                .font(.system(size: 25, weight: emphasized ? .semibold : .medium))
                .tracking(-0.5)
                .monospacedDigit()
                .foregroundStyle(emphasized ? PrismTheme.text : PrismTheme.textSecondary)
                .lineLimit(1)
                .minimumScaleFactor(0.4)
                .textSelection(.disabled)
            if !detail.isEmpty || reservesDetail {
                Text(verbatim: detail.isEmpty ? " " : detail)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(PrismTheme.textMuted)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                    .padding(.horizontal, 9)
                    .padding(.vertical, 3)
                    .background(Capsule().fill(PrismTheme.surfaceStrong))
                    .opacity(detail.isEmpty ? 0 : 1)
            }
        }
        .padding(.horizontal, 18)
        .frame(maxWidth: .infinity)
    }
}

/// Related answers below a card, three to a line.
struct PaletteAnswerGrid<Cell: View>: View {
    let rows: [PaletteModel.Section.Row]
    @ViewBuilder let cell: (PaletteModel.Section.Row) -> Cell
    private static var columns: Int { 3 }

    var body: some View {
        VStack(spacing: 8) {
            ForEach(Array(stride(from: 0, to: rows.count, by: Self.columns)), id: \.self) { start in
                HStack(spacing: 8) {
                    ForEach(rows[start..<min(start + Self.columns, rows.count)]) { row in
                        cell(row).frame(maxWidth: .infinity)
                    }
                    ForEach(0..<(Self.columns - min(Self.columns, rows.count - start)), id: \.self) { _ in
                        Color.clear.frame(maxWidth: .infinity, maxHeight: 1)
                    }
                }
            }
        }
        .padding(.top, 4)
        .padding(.bottom, 4)
    }
}

struct PaletteAnswerCell: View {
    let answer: PaletteAnswer
    let isSelected: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(verbatim: answer.output)
                .font(.system(size: 15, weight: .semibold))
                .monospacedDigit()
                .foregroundStyle(PrismTheme.text)
                .lineLimit(1)
                .minimumScaleFactor(0.55)
            if !answer.outputDetail.isEmpty {
                Text(verbatim: answer.outputDetail)
                    .font(.system(size: 10.5))
                    .foregroundStyle(PrismTheme.textMuted)
                    .lineLimit(1)
            }
        }
        .padding(.horizontal, 13)
        .frame(maxWidth: .infinity, minHeight: 56, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(isSelected ? PrismTheme.surfaceStrong : PrismTheme.surface))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(isSelected ? PrismTheme.lineStrong : PrismTheme.line))
        .accessibilityElement(children: .combine)
    }
}

/// One highlight belongs to the list, rather than a retained background on every recycled row.
private struct PaletteRowBounds: SwiftUI.PreferenceKey {
    static var defaultValue: [String: Anchor<CGRect>] { [:] }
    static func reduce(value: inout [String: Anchor<CGRect>], nextValue: () -> [String: Anchor<CGRect>]) {
        value.merge(nextValue(), uniquingKeysWith: { _, latest in latest })
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
                .font(.system(size: 15, weight: .regular))
                .foregroundStyle(isSelected ? PrismTheme.accentStrong : PrismTheme.textSecondary)
        case .file(let path):
            if showFileIcons {
                PrismFileIcon(path: path)
                    // Keep the icon compact within the 26pt row slot.
                    .frame(width: 24, height: 24)
                    .allowsHitTesting(false)
            } else {
                Image(systemName: "app").font(.system(size: 15, weight: .regular)).foregroundStyle(PrismTheme.textSecondary)
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
