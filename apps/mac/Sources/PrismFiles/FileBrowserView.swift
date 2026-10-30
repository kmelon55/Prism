import AppKit
import PrismKit
import QuickLookThumbnailing
import SwiftUI

struct FileBrowserView: View {
    @Bindable var model: FileBrowserModel
    var onClose: () -> Void

    var body: some View {
        Group {
            if let target = model.openWithTarget {
                OpenWithView(hit: target, onOpen: { model.hidePalette() }, onCancel: { model.closeOpenWith() })
            } else {
                browser
            }
        }
        .task { model.start() }
        .onDisappear { QuickLookPanel.shared.close() }
    }

    private var browser: some View {
        VStack(spacing: 0) {
            header
            ZStack {
                Group {
                    if model.results.isEmpty {
                        list
                    } else {
                        GeometryReader { proxy in
                            HStack(spacing: 0) {
                                list.frame(width: (proxy.size.width * 0.56).rounded())
                                PrismVerticalRule()
                                FilePreviewPane(hit: model.selectedHit)
                            }
                        }
                    }
                }
                .prismActionPanelBlur(model.showsActions)
                if model.showsActions, let hit = model.selectedHit {
                    let actions = model.selectedActions
                    PrismActionPanel(
                        title: hit.name, actions: actions, selection: model.actionSelection,
                        searchPrompt: String(localized: "Search actions…", bundle: .module),
                        emptyText: String(localized: "No matching actions", bundle: .module),
                        onSelect: { index in
                            guard actions.indices.contains(index) else { return }
                            model.toggleActions()
                            model.perform(actions[index])
                        },
                        onDismiss: { model.toggleActions() }
                    )
                }
            }
            footer
        }
    }

    private var header: some View {
        PrismScreenHeader {
            PrismBackButton(help: Text("Back", bundle: .module), action: onClose)
            HStack(spacing: 9) {
                PrismSearchGlyph()
                ScreenSearchField(
                    text: $model.query,
                    placeholder: String(localized: "Search files by name", bundle: .module),
                    onCommand: model.handle,
                    onKeyEquivalent: model.handleKeyEquivalent
                )
            }
            Menu {
                Picker(selection: $model.filter) {
                    ForEach(FileTypeFilter.allCases) { filter in
                        Label(filter.title, systemImage: filter.systemImage).tag(filter)
                    }
                } label: {
                    Text("File type", bundle: .module)
                }
                .pickerStyle(.inline)
            } label: {
                HStack(spacing: 7) {
                    Text(verbatim: model.filter.title).foregroundStyle(PrismTheme.textSecondary)
                    Image(systemName: "chevron.down").font(.system(size: 9, weight: .semibold)).foregroundStyle(PrismTheme.textMuted)
                }
                .font(.prism(11))
                .padding(.horizontal, 9)
                .frame(height: 26)
                .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(PrismTheme.control))
                .overlay(RoundedRectangle(cornerRadius: 7, style: .continuous).strokeBorder(PrismTheme.lineStrong))
                .contentShape(Rectangle())
            }
            .menuStyle(.button)
            .buttonStyle(.plain)
            .menuIndicator(.hidden)
            .fixedSize()
            .help(Text("File type (⇥)", bundle: .module))
        }
    }

    @ViewBuilder
    private var list: some View {
        if model.results.isEmpty {
            if model.isSearching {
                PrismLoadingRows().padding(.horizontal, 12)
            } else {
                PrismEmptyState(title: Text(verbatim: emptyTitle), message: Text(verbatim: emptyDetail))
            }
        } else {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        if model.query.trimmingCharacters(in: .whitespaces).isEmpty {
                            PrismSectionLabel(String(localized: "Recently Used", bundle: .module), isFirst: true)
                        }
                        ForEach(Array(model.results.enumerated()), id: \.element.id) { index, hit in
                            FileRow(hit: hit, isSelected: index == model.selection)
                                .id(hit.id)
                                .contentShape(Rectangle())
                                .onTapGesture(count: 2) {
                                    model.selection = index
                                    _ = model.handle(.submit)
                                }
                                .onTapGesture { model.selection = index }
                                .contextMenu { contextMenu(for: index) }
                        }
                    }
                    .padding(.horizontal, 12)
                    .padding(.top, 5)
                    .padding(.bottom, 10)
                }
                .scrollIndicators(.never)
                .opacity(model.isCurrent ? 1 : 0.6)
                .onChange(of: model.selection) { _, selection in
                    guard model.results.indices.contains(selection) else { return }
                    proxy.scrollTo(model.results[selection].id)
                }
            }
        }
    }

    @ViewBuilder
    private func contextMenu(for index: Int) -> some View {
        if model.results.indices.contains(index) {
            let hit = model.results[index]
            ForEach(FileActions.actions(for: hit) { hit in
                model.selection = model.results.firstIndex(of: hit) ?? model.selection
                model.toggleActions()
                return .keepOpen
            }.filter { $0.id != "file-open-with" }) { action in
                Button {
                    model.selection = index
                    model.perform(action)
                } label: {
                    Label(action.title, systemImage: action.systemImage ?? "circle")
                }
            }
        }
    }

    private var emptyTitle: String {
        if model.query.trimmingCharacters(in: .whitespaces).isEmpty {
            return model.service.spotlightEnabled
                ? String(localized: "No recently used files", bundle: .module)
                : String(localized: "Type to search files", bundle: .module)
        }
        return String(localized: "No matching files", bundle: .module)
    }

    private var emptyDetail: String {
        model.query.trimmingCharacters(in: .whitespaces).isEmpty
            ? String(localized: "Search your home folder and the folders you add in Settings.", bundle: .module)
            : String(localized: "Try another name, or add folders outside your home folder in Settings.", bundle: .module)
    }

    private var footer: some View {
        PrismStatusBar {
            Group {
                if let status = model.status {
                    Text(verbatim: status)
                } else if model.service.isIndexing {
                    Text("Updating the file index…", bundle: .module)
                } else if model.isCurrent, !model.results.isEmpty, !model.query.trimmingCharacters(in: .whitespaces).isEmpty {
                    Text(countText)
                }
            }
            .lineLimit(1)
            .padding(.horizontal, 7)
        } trailing: {
            if model.selectedHit != nil {
                PrismStatusAction(Text("Open", bundle: .module), keys: "↵", isPrimary: true) { _ = model.handle(.submit) }
                    .disabled(model.showsActions)
                PrismStatusDivider()
                PrismStatusAction(Text("Quick Look", bundle: .module), keys: "⌘Y") {
                    if let action = model.selectedActions.first(where: { $0.id == "file-quick-look" }) { model.perform(action) }
                }
                PrismStatusDivider()
                PrismStatusAction(Text("Actions", bundle: .module), keys: "⌘K", isActive: model.showsActions) { model.toggleActions() }
            }
        }
    }

    private var countText: String {
        let shown = model.results.count
        return model.total > shown
            ? String(localized: "\(shown) of \(model.total) files", bundle: .module)
            : String(localized: "\(shown) files", bundle: .module)
    }
}

struct FileRow: View {
    let hit: FileHit
    let isSelected: Bool

    var body: some View {
        HStack(spacing: 10) {
            Image(nsImage: AppIconCache.shared.icon(forPath: hit.path))
                .resizable()
                .frame(width: 26, height: 26)
            VStack(alignment: .leading, spacing: 3) {
                Text(verbatim: hit.name)
                    .font(.prism(13, weight: 550))
                    .foregroundStyle(PrismTheme.text)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(verbatim: hit.displayLocation)
                    .font(.prism(10))
                    .foregroundStyle(PrismTheme.textMuted)
                    .lineLimit(1)
                    .truncationMode(.head)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 11)
        .frame(minHeight: 46)
        .prismRowBackground(isSelected: isSelected)
    }
}

/// Thumbnail and metadata for the selected file. Thumbnails come from Quick Look at a bounded size and are
/// requested only for the selection.
struct FilePreviewPane: View {
    let hit: FileHit?
    @ViewState private var thumbnail: NSImage?
    @ViewState private var info: FileInfo?

    struct FileInfo: Equatable {
        var kind: String
        var size: Int64?
        var modified: Date?
        var created: Date?
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let hit {
                ZStack {
                    if let thumbnail {
                        Image(nsImage: thumbnail)
                            .resizable()
                            .aspectRatio(contentMode: .fit)
                            .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
                    } else {
                        Image(nsImage: AppIconCache.shared.icon(forPath: hit.path))
                            .resizable()
                            .frame(width: 96, height: 96)
                    }
                }
                .frame(maxWidth: .infinity)
                .frame(height: 170)
                Text(verbatim: hit.name)
                    .font(.prism(13, weight: 550))
                    .foregroundStyle(PrismTheme.text)
                    .lineLimit(2)
                    .truncationMode(.middle)
                PrismRule()
                Grid(alignment: .leading, horizontalSpacing: 8, verticalSpacing: 7) {
                    row(String(localized: "Kind", bundle: .module), info?.kind ?? FileActions.kind(of: hit))
                    if let size = info?.size {
                        row(String(localized: "Size", bundle: .module), size.formatted(.byteCount(style: .file)))
                    }
                    if let modified = info?.modified {
                        row(String(localized: "Modified", bundle: .module), modified.formatted(date: .abbreviated, time: .shortened))
                    }
                    row(String(localized: "Where", bundle: .module), hit.displayLocation)
                }
                .font(.prism(11))
                Spacer(minLength: 0)
            } else {
                Spacer()
            }
        }
        .padding(18)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .task(id: hit?.path) { await load() }
    }

    private func row(_ label: String, _ value: String) -> some View {
        GridRow {
            Text(verbatim: label).foregroundStyle(PrismTheme.textMuted).frame(width: 62, alignment: .leading)
            Text(verbatim: value).foregroundStyle(PrismTheme.textSecondary).lineLimit(2).truncationMode(.middle)
        }
    }

    private func load() async {
        thumbnail = nil
        info = nil
        guard let hit else { return }
        let url = hit.url
        let values = try? url.resourceValues(forKeys: [.localizedTypeDescriptionKey, .fileSizeKey, .contentModificationDateKey, .creationDateKey])
        info = FileInfo(
            kind: values?.localizedTypeDescription ?? FileActions.kind(of: hit),
            size: hit.isDirectory ? nil : values?.fileSize.map(Int64.init),
            modified: values?.contentModificationDate, created: values?.creationDate
        )
        let request = QLThumbnailGenerator.Request(
            fileAt: url, size: CGSize(width: 220, height: 160), scale: NSScreen.main?.backingScaleFactor ?? 2,
            representationTypes: .thumbnail
        )
        let image = try? await QLThumbnailGenerator.shared.generateBestRepresentation(for: request).nsImage
        guard !Task.isCancelled else { return }
        thumbnail = image
    }
}
