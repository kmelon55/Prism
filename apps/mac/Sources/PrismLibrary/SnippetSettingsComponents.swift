import PrismKit
import SwiftUI

// Small building blocks for the Snippets settings page: flat list rows separated by hairlines, like the Tauri
// `.script-directory-row` and `.settings-command-row`, with quiet icon buttons.

/// A full-width hairline between list rows.
struct SnippetSettingsDivider: View {
    var body: some View {
        Rectangle().fill(PrismTheme.separator).frame(height: 1)
    }
}

/// One list entry: a 20 pt icon, a title with an optional muted detail, trailing buttons, then a hairline.
struct SnippetSettingsListRow<Icon: View, Accessory: View>: View {
    let title: String
    let detail: String?
    let icon: Icon
    let accessory: Accessory

    init(title: String, detail: String?, @ViewBuilder icon: () -> Icon, @ViewBuilder accessory: () -> Accessory) {
        self.title = title
        self.detail = detail
        self.icon = icon()
        self.accessory = accessory()
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                icon.frame(width: 20, height: 20)
                VStack(alignment: .leading, spacing: 2) {
                    Text(verbatim: title)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(PrismTheme.text)
                        .lineLimit(1)
                    if let detail {
                        Text(verbatim: detail)
                            .font(.system(size: 11))
                            .foregroundStyle(PrismTheme.textMuted)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                }
                Spacer(minLength: 12)
                accessory
            }
            .padding(.horizontal, 4)
            .frame(minHeight: 50)
            SnippetSettingsDivider()
        }
    }
}

/// The muted line shown when a list is empty (`.settings-table-empty`).
struct SnippetSettingsEmptyRow: View {
    let text: String

    var body: some View {
        VStack(spacing: 0) {
            Text(verbatim: text)
                .font(.system(size: 12))
                .foregroundStyle(PrismTheme.textMuted)
                .frame(maxWidth: .infinity, minHeight: 50, alignment: .leading)
            SnippetSettingsDivider()
        }
    }
}

/// A borderless glyph button for row actions such as remove or reorder.
struct SnippetSettingsIconButton: View {
    let systemImage: String
    let help: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 10, weight: .semibold))
                .frame(width: 14, height: 14)
        }
        .buttonStyle(.prismGhost)
        .help(help)
        .accessibilityLabel(Text(verbatim: help))
    }
}

/// An inline error line with a warning glyph (`.preference-alert`).
struct SnippetSettingsAlert: View {
    let text: String

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 7) {
            Image(systemName: "exclamationmark.triangle").font(.system(size: 11))
            Text(verbatim: text).font(.system(size: 11)).fixedSize(horizontal: false, vertical: true)
        }
        .foregroundStyle(PrismTheme.danger)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
