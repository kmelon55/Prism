import AppKit
import PrismKit
import SwiftUI

/// The header of a library screen inside the palette: back arrow, field and an optional trailing view.
struct ScreenHeader<Field: View, Trailing: View>: View {
    var onBack: (() -> Void)?
    @ViewBuilder var field: Field
    @ViewBuilder var trailing: Trailing

    var body: some View {
        PrismScreenHeader {
            if let onBack {
                PrismBackButton(help: Text("Back", bundle: .module), action: onBack)
            }
            field
            trailing
        }
    }
}

/// A library glyph: line symbols in the secondary text color, Finder icons for paths.
struct LibraryIconView: View {
    let icon: PaletteIcon

    var body: some View {
        switch icon {
        case .symbol(let name, _):
            Image(systemName: PrismGlyph.outline(name))
                .font(.system(size: 15, weight: .light))
                .foregroundStyle(PrismTheme.textSecondary)
        case .file(let path):
            Image(nsImage: AppIconCache.shared.icon(forPath: path)).resizable()
        case .image(let image):
            Image(nsImage: image).resizable().aspectRatio(contentMode: .fit)
        case .text(let text):
            Text(verbatim: text).font(.system(size: 18))
        case .none:
            Color.clear
        }
    }
}

/// One saved entry (`.library-row`): title over its value, then quiet open/copy and delete buttons. Rows are
/// separated by hairlines; the keyboard selection gets the palette's selection fill.
struct LibraryRowView: View {
    let row: LibraryScreenModel.Row
    let tab: LibraryScreenModel.Tab
    let isSelected: Bool
    var onPrimary: () -> Void
    var onDelete: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            if tab == .favorites {
                Image(systemName: "star").font(.system(size: 12)).foregroundStyle(PrismTheme.textSecondary)
            }
            VStack(alignment: .leading, spacing: 4) {
                Text(verbatim: row.title.isEmpty ? " " : row.title)
                    .font(.prism(12, weight: 550))
                    .foregroundStyle(PrismTheme.text)
                    .lineLimit(1)
                if !row.subtitle.isEmpty || tab == .favorites {
                    Text(verbatim: row.subtitle.isEmpty ? row.accessory : row.subtitle)
                        .font(.prism(11))
                        .foregroundStyle(PrismTheme.textMuted)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
            }
            Spacer(minLength: 12)
            if row.isFavorite && tab != .favorites {
                Image(systemName: "star").font(.system(size: 10)).foregroundStyle(PrismTheme.textMuted)
            }
            if tab != .favorites, !row.accessory.isEmpty {
                Text(verbatim: row.accessory)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(PrismTheme.textMuted)
                    .lineLimit(1)
            }
            if let entry = row.entry, tab != .favorites {
                let copies = entry.kind == .snippet
                PrismIconButton(systemImage: copies ? "doc.on.doc" : (entry.kind == .note ? "square.and.pencil" : "folder"),
                                help: Text(verbatim: copies ? L10n.tr("Copy") : L10n.tr("Open")), action: onPrimary)
                    .focusable(false)
            }
            PrismIconButton(systemImage: "trash", help: Text(verbatim: tab == .favorites ? L10n.tr("Remove") : L10n.tr("Delete")), action: onDelete)
                .focusable(false)
        }
        .padding(.horizontal, 11)
        .padding(.vertical, 9)
        .frame(minHeight: 65)
        .background {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(isSelected ? AnyShapeStyle(PrismTheme.selection) : AnyShapeStyle(Color.clear))
        }
        .overlay {
            RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(isSelected ? PrismTheme.lineStrong : .clear)
        }
        .overlay(alignment: .bottom) {
            if !isSelected { PrismRule().padding(.horizontal, 1) }
        }
        .contentShape(Rectangle())
    }
}

/// The inline delete confirmation (`.library-confirm`): Return confirms, Escape cancels.
struct LibraryConfirmation: View {
    let message: String
    let confirmTitle: String
    var onCancel: () -> Void
    var onConfirm: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Text(verbatim: message)
                .font(.prism(12, weight: 500))
                .foregroundStyle(PrismTheme.text)
                .lineLimit(1)
            Spacer(minLength: 8)
            Button(action: onConfirm) {
                HStack(spacing: 6) { Text(verbatim: confirmTitle); KeyCap("↵") }
            }
            .buttonStyle(.prismDestructive)
            Button(action: onCancel) {
                HStack(spacing: 6) { Text("Cancel", bundle: .module); KeyCap("esc") }
            }
            .buttonStyle(.prism)
        }
        .padding(15)
        .background(PrismTheme.panel, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(PrismTheme.lineStrong))
        .shadow(color: .black.opacity(0.18), radius: 20, y: 8)
    }
}
