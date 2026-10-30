import AppKit
import PrismKit
import SwiftUI

/// The selected entry's content and details. Full text and image thumbnails load only for the selection;
/// a late answer for an earlier selection is dropped because the pane is rebuilt per entry.
struct ClipboardPreviewPane: View {
    let entry: ClipboardEntry
    let store: ClipboardStore

    @ViewState private var fullText: String?
    @ViewState private var image: NSImage?
    @ViewState private var loadError: String?
    @ViewState private var attempt = 0

    private static let imagePixelSize = 640

    var body: some View {
        let presentation = EntryPresentation(entry: entry)
        // `.clipboard-entry-preview`: a kind heading, the content, then metadata under a hairline.
        VStack(alignment: .leading, spacing: 0) {
            heading(presentation)
                .padding([.horizontal, .top], 18)
                .padding(.bottom, 16)
            if case .image = presentation.style {
                // Images scale to the space above the details instead of scrolling.
                preview(presentation)
                    .padding(.horizontal, 18)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    preview(presentation)
                        .frame(maxWidth: .infinity, alignment: .topLeading)
                        .padding(.horizontal, 18)
                }
                .scrollIndicators(.never)
                .frame(maxHeight: .infinity)
            }
            details(presentation)
                .padding(.top, 12)
                .overlay(alignment: .top) { PrismRule() }
                .padding(.horizontal, 18)
                .padding(.vertical, 14)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .task(id: attempt) { await load() }
    }

    private func load() async {
        loadError = nil
        do {
            switch entry.kind {
            case .text:
                // Search returns at most 500 characters; fetch the original with its line breaks.
                guard entry.text.count > ClipboardLimits.searchPreviewCharacters || entry.text.hasSuffix("…") else { return }
                let id = entry.id
                fullText = try await Task.detached(priority: .userInitiated) { [store] in
                    Result { () throws(ClipboardError) in try store.text(id: id) }
                }.value.get()
            case .image:
                image = ThumbnailLoader.shared.cached(id: entry.id, maxPixelSize: Self.imagePixelSize)
                if image == nil {
                    image = await ThumbnailLoader.shared.image(id: entry.id, maxPixelSize: Self.imagePixelSize, store: store)
                    if image == nil && !Task.isCancelled { loadError = ClipboardText.localize("Image preview unavailable") }
                }
            case .files:
                break
            }
        } catch {
            if !Task.isCancelled { loadError = error.localizedDescription }
        }
    }

    private func heading(_ presentation: EntryPresentation) -> some View {
        HStack(spacing: 8) {
            Image(systemName: presentation.symbol).font(.system(size: 13, weight: .light))
            Text(verbatim: presentation.kindTitle).font(.prism(12, weight: 600))
        }
        .foregroundStyle(PrismTheme.text)
    }

    @ViewBuilder
    private func preview(_ presentation: EntryPresentation) -> some View {
        switch presentation.style {
        case .image:
            Group {
                if let image {
                    Image(nsImage: image)
                        .resizable()
                        .interpolation(.high)
                        .aspectRatio(contentMode: .fit)
                        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(PrismTheme.lineStrong))
                        .frame(maxWidth: CGFloat(entry.width ?? 640), maxHeight: CGFloat(entry.height ?? 640))
                        .accessibilityLabel(Text("Clipboard image preview", bundle: .module))
                } else if loadError == nil {
                    ProgressView().controlSize(.small)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .files(let paths):
            VStack(alignment: .leading, spacing: 8) {
                ForEach(paths.prefix(64), id: \.self) { path in
                    HStack(spacing: 10) {
                        Image(nsImage: AppIconCache.shared.icon(forPath: path))
                            .resizable()
                            .frame(width: 28, height: 28)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(verbatim: URL(filePath: path).lastPathComponent)
                                .font(.prism(12, weight: 550))
                                .foregroundStyle(PrismTheme.text)
                                .lineLimit(1)
                            Text(verbatim: ((path as NSString).deletingLastPathComponent as NSString).abbreviatingWithTildeInPath)
                                .font(.prism(11))
                                .foregroundStyle(PrismTheme.textMuted)
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }
                    }
                }
            }
        case .color(let color):
            VStack(alignment: .leading, spacing: 12) {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(Color(nsColor: color))
                    .frame(height: 96)
                    .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(PrismTheme.lineStrong))
                textBody
            }
        case .text, .link:
            textBody
        }
        if let loadError {
            HStack(spacing: 6) {
                Image(systemName: "exclamationmark.triangle").foregroundStyle(PrismTheme.warning)
                Text(verbatim: loadError).font(.prism(12)).foregroundStyle(PrismTheme.textSecondary)
                Button { attempt += 1 } label: { Text("Retry", bundle: .module) }
                    .buttonStyle(.prismGhost)
            }
            .padding(.top, 8)
        }
    }

    private var textBody: some View {
        Text(verbatim: fullText ?? entry.text)
            .font(.prism(12))
            .foregroundStyle(PrismTheme.textSecondary)
            .lineSpacing(5)
            .textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func details(_ presentation: EntryPresentation) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            DetailRow(label: Text("Type", bundle: .module), value: presentation.kindTitle)
            switch entry.kind {
            case .text:
                let text = fullText ?? entry.text
                DetailRow(label: Text("Characters", bundle: .module), value: text.count.formatted(.number.locale(ClipboardFormat.locale)))
            case .image:
                if let width = entry.width, let height = entry.height {
                    DetailRow(label: Text("Dimensions", bundle: .module), value: "\(width) × \(height)")
                }
                if let mimeType = entry.mimeType {
                    DetailRow(label: Text("Format", bundle: .module), value: mimeType.replacingOccurrences(of: "image/", with: "").uppercased())
                }
            case .files:
                DetailRow(label: Text("Files", bundle: .module), value: entry.fileCount.formatted(.number.locale(ClipboardFormat.locale)))
            }
            DetailRow(label: Text("Size", bundle: .module), value: ClipboardFormat.bytes(entry.byteSize))
            DetailRow(label: Text("Copied", bundle: .module), value: ClipboardFormat.dateTime(entry.capturedAt))
            if let note {
                Text(verbatim: note)
                    .font(.prism(11))
                    .foregroundStyle(PrismTheme.textMuted)
                    .lineSpacing(2)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 2)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var note: String? {
        switch entry.kind {
        case .text: nil
        case .image: ClipboardText.localize("Copy and paste reuse the original image. Image display depends on the destination app.")
        case .files: ClipboardText.localize("File availability is checked when you copy or paste.")
        }
    }
}

private struct DetailRow: View {
    let label: Text
    let value: String

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            label.foregroundStyle(PrismTheme.textMuted)
            Spacer(minLength: 12)
            Text(verbatim: value)
                .foregroundStyle(PrismTheme.textSecondary)
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .font(.prism(11))
    }
}
