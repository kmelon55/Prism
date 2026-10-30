import PrismKit
import SwiftUI

struct EmojiPickerView: View {
    @Bindable var model: EmojiPickerModel
    var onClose: () -> Void
    var onOpenAccessibilitySettings: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            header
            categoryBar
            content
            if let failure = model.failure {
                failureBanner(failure)
            }
            footer
        }
        .task { await model.load() }
        .onDisappear { EmojiCatalogLoader.shared.scheduleRelease() }
    }

    // MARK: Header

    private var header: some View {
        // `.emoji-header`: back arrow, magnifier, search field and the skin tone select.
        PrismScreenHeader {
            PrismBackButton(help: Text("Close emoji picker", bundle: .module), action: onClose)
                .disabled(model.busy)
            HStack(spacing: 9) {
                PrismSearchGlyph()
                ScreenSearchField(
                    text: $model.query,
                    placeholder: String(localized: "Search in Korean or English", bundle: .module),
                    onCommand: handle
                )
            }
            skinToneMenu
        }
    }

    private var skinToneMenu: some View {
        Menu {
            Picker(selection: $model.tone) {
                ForEach(SkinTone.allCases) { tone in
                    Text(verbatim: "\(tone.swatch)  \(tone.title)").tag(tone)
                }
            } label: {
                Text("Skin tone", bundle: .module)
            }
            .pickerStyle(.inline)
        } label: {
            HStack(spacing: 5) {
                Text(verbatim: model.tone.swatch)
                Text(verbatim: model.tone.title)
                Image(systemName: "chevron.down")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(PrismTheme.textMuted)
                    .padding(.leading, 18)
            }
            .font(.prism(12))
            .foregroundStyle(PrismTheme.textSecondary)
            .padding(.horizontal, 6)
            .frame(height: 30)
            .contentShape(Rectangle())
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .help(Text("Skin tone", bundle: .module))
    }

    private func handle(_ command: SearchFieldCommand) -> Bool {
        switch command {
        case .submit:
            Task { await model.performPrimary() }
            return true
        case .commandSubmit:
            Task { model.failure?.operation == .paste ? await model.copyInstead() : await model.performCopy() }
            return true
        case .tab:
            model.cycleCategory(by: 1)
            return true
        case .backTab:
            model.cycleCategory(by: -1)
            return true
        case .cancel:
            if model.busy { return true }
            if model.failure != nil {
                model.dismissFailure()
                return true
            }
            if !model.query.isEmpty {
                model.query = ""
                return true
            }
            return false
        default:
            return model.move(command)
        }
    }

    // MARK: Categories

    private var categoryBar: some View {
        // `.emoji-categories`: equal-width buttons; the selected one is filled with an accent rule below.
        HStack(spacing: 2) {
            ForEach(model.categories) { category in
                let selected = !model.isSearching && model.category == category.id
                Button { model.select(category: category.id) } label: {
                    Text(verbatim: category.glyph)
                        .font(.system(size: category.glyph.unicodeScalars.first?.properties.isEmojiPresentation == true ? 20 : 17))
                        .foregroundStyle(PrismTheme.textSecondary)
                        .frame(maxWidth: .infinity, minHeight: 34)
                        .background {
                            RoundedRectangle(cornerRadius: 7, style: .continuous)
                                .fill(selected ? PrismTheme.surfaceSelected : .clear)
                        }
                        .overlay(alignment: .bottom) {
                            if selected {
                                UnevenRoundedRectangle(bottomLeadingRadius: 7, bottomTrailingRadius: 7, style: .continuous)
                                    .fill(PrismTheme.accent)
                                    .frame(height: 2)
                            }
                        }
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .focusable(false)
                .help(Text(verbatim: category.title(korean: model.useKorean)))
                .accessibilityLabel(Text(verbatim: category.title(korean: model.useKorean)))
            }
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 8)
        .overlay(alignment: .bottom) { PrismRule() }
    }

    // MARK: Grid

    @ViewBuilder
    private var content: some View {
        if model.catalog == nil {
            if model.loadFailed {
                PrismEmptyState(symbol: "exclamationmark.triangle", title: Text("Emoji could not be loaded.", bundle: .module),
                                button: (Text("Retry loading", bundle: .module), { Task { await model.load() } }))
            } else {
                Text("Loading emoji…", bundle: .module)
                    .font(.prism(13))
                    .foregroundStyle(PrismTheme.textMuted)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        } else if model.items.isEmpty {
            emptyState
        } else {
            grid
        }
    }

    private var emptyState: some View {
        let recentEmpty = !model.isSearching && model.category == EmojiCategory.recent.id
        return PrismEmptyState(
            title: Text(recentEmpty ? "No recent emoji yet" : "No matching emoji", bundle: .module),
            message: Text(recentEmpty ? "Your successful choices appear here." : "Try another word in Korean or English.", bundle: .module)
        )
    }

    private var grid: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 0), count: EmojiPickerModel.columns), spacing: 0) {
                    ForEach(Array(model.items.enumerated()), id: \.offset) { index, item in
                        EmojiCell(emoji: item.emoji, isSelected: index == model.selection)
                            .id(index)
                            .help(Text(verbatim: model.label(item)))
                            .accessibilityLabel(Text(verbatim: model.label(item)))
                            .onTapGesture {
                                model.selection = index
                                Task { await model.performPrimary() }
                            }
                            .contextMenu {
                                Button { Task { await model.perform(item.emoji, .paste) } } label: {
                                    Label { Text("Paste", bundle: .module) } icon: { Image(systemName: "doc.on.clipboard") }
                                }
                                Button { Task { await model.perform(item.emoji, .copy) } } label: {
                                    Label { Text("Copy", bundle: .module) } icon: { Image(systemName: "doc.on.doc") }
                                }
                            }
                    }
                }
                .padding(.horizontal, 18)
                .padding(.vertical, 10)
                .disabled(model.busy)
            }
            .scrollIndicators(.never)
            .onChange(of: model.selection) { _, selection in
                proxy.scrollTo(selection)
            }
            .onChange(of: model.items.count) {
                proxy.scrollTo(0, anchor: .top)
            }
            .overlay(alignment: .bottom) {
                if model.storageFailed {
                    Text("Recent choices could not be saved on this device.", bundle: .module)
                        .font(.prism(11))
                        .foregroundStyle(PrismTheme.textMuted)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .background(PrismTheme.panel, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                        .padding(.bottom, 8)
                }
            }
        }
    }

    // MARK: Failure and footer

    private func failureBanner(_ failure: EmojiFailure) -> some View {
        // `.emoji-error`: a danger-tinted line with quiet buttons.
        HStack(alignment: .center, spacing: 8) {
            VStack(alignment: .leading, spacing: 4) {
                Group {
                    if failure.needsAccessibility {
                        Text("Pasting needs Accessibility permission.", bundle: .module)
                    } else {
                        Text(failure.operation == .copy ? "Copy failed. Try again when ready." : "Paste failed. Check the original app, then retry.", bundle: .module)
                    }
                }
                .font(.prism(12))
                .foregroundStyle(PrismTheme.danger)
                if let detail = failure.detail {
                    Text(verbatim: detail).font(.prism(11)).foregroundStyle(PrismTheme.textSecondary).lineLimit(2)
                }
            }
            Spacer(minLength: 8)
            if failure.needsAccessibility {
                Button(action: onOpenAccessibilitySettings) { Text("Open Settings", bundle: .module) }
            } else {
                Button { Task { await model.retry() } } label: {
                    Text(failure.operation == .copy ? "Retry copy" : "Retry paste", bundle: .module)
                }
            }
            if failure.operation == .paste {
                Button { Task { await model.copyInstead() } } label: { Text("Copy instead", bundle: .module) }
            }
            Button { model.dismissFailure() } label: { Text("Dismiss", bundle: .module) }
        }
        .buttonStyle(.prism)
        .disabled(model.busy)
        .padding(.horizontal, 18)
        .padding(.vertical, 9)
        .overlay(alignment: .top) { PrismRule() }
    }

    private var footer: some View {
        // `.emoji-footer`: the selection preview and name, then the paste and copy actions.
        HStack(spacing: 12) {
            HStack(spacing: 10) {
                Text(verbatim: model.selectedItem?.emoji ?? "☺️").font(.system(size: 22))
                Text(verbatim: model.selectedItem.map(model.label) ?? String(localized: "Choose an emoji", bundle: .module))
                    .font(.prism(12))
                    .foregroundStyle(PrismTheme.textSecondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 8)
            if model.busy {
                Text("Working…", bundle: .module).font(.prism(12)).foregroundStyle(PrismTheme.textMuted)
            } else if let status = model.status {
                Text(verbatim: status).font(.prism(12)).foregroundStyle(PrismTheme.textMuted)
            }
            if model.selectedItem != nil {
                HStack(spacing: 2) {
                    ModeButton(title: Text("Paste", bundle: .module), keys: "↵", isPrimary: true) {
                        Task { await model.performPrimary() }
                    }
                    ModeButton(title: Text("Copy", bundle: .module), keys: "⌘↵", isPrimary: false) {
                        Task { model.failure?.operation == .paste ? await model.copyInstead() : await model.performCopy() }
                    }
                }
                .padding(3)
                .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(PrismTheme.surface))
                .disabled(model.busy)
            }
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 8)
        .frame(minHeight: 53)
        .overlay(alignment: .top) { PrismRule() }
    }
}

/// One button of the footer's action group (`.emoji-modes`): the primary action is drawn selected.
private struct ModeButton: View {
    let title: Text
    let keys: String
    let isPrimary: Bool
    let action: () -> Void
    @ViewState private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                title
                PrismShortcutCaps(keys)
            }
            .font(.prism(12))
            .foregroundStyle(isPrimary || hovering ? PrismTheme.text : PrismTheme.textMuted)
            .padding(.leading, 10)
            .padding(.trailing, 6)
            .frame(height: 26)
            .background(RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(isPrimary ? PrismTheme.surfaceSelected : (hovering ? PrismTheme.surfaceStrong : .clear)))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}

private struct EmojiCell: View {
    let emoji: String
    let isSelected: Bool

    var body: some View {
        Text(verbatim: emoji)
            .font(.system(size: 30))
            .frame(maxWidth: .infinity, minHeight: 49)
            .background {
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(isSelected ? PrismTheme.surfaceSelected : .clear)
            }
            .contentShape(Rectangle())
    }
}
