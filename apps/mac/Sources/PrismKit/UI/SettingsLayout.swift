import SwiftUI

// The settings page layout of the Tauri app (`.settings-content`, `.settings-group`, `.settings-row`):
// flat rows on the glass, small group titles, generous spacing, no boxed forms.

/// A settings page: a 96 pt header with the pane title, then a scrolling column of groups.
public struct PrismSettingsPage<Content: View>: View {
    let title: String
    let content: Content

    public init(_ title: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(verbatim: title)
                .font(.system(size: 21, weight: .semibold))
                .tracking(-0.63)
                .foregroundStyle(PrismTheme.text)
                .padding(.horizontal, 30)
                .frame(height: 96, alignment: .bottomLeading)
                .padding(.bottom, -4)
            ScrollView {
                VStack(alignment: .leading, spacing: 28) { content }
                    .padding(EdgeInsets(top: 24, leading: 30, bottom: 32, trailing: 30))
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .scrollIndicators(.automatic)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

/// A titled run of rows. The title is optional, as in the Tauri General page's first group.
public struct PrismSettingsGroup<Content: View, Accessory: View>: View {
    let title: Text?
    let accessory: Accessory
    let content: Content

    public init(_ title: Text? = nil, @ViewBuilder accessory: () -> Accessory = { EmptyView() }, @ViewBuilder content: () -> Content) {
        self.title = title
        self.accessory = accessory()
        self.content = content()
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let title {
                HStack(alignment: .firstTextBaseline) {
                    title
                        .font(.system(size: 11, weight: .semibold))
                        .tracking(-0.055)
                        .foregroundStyle(PrismTheme.textSecondary)
                    Spacer(minLength: 12)
                    accessory
                }
                .padding(.top, 8)
                .padding(.bottom, 12)
            }
            content
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// One setting: a 12 pt title with an optional muted explanation on the left, its control on the right.
public struct PrismSettingsRow<Control: View>: View {
    let title: Text
    let detail: Text?
    let stacked: Bool
    let control: Control

    /// `stacked` puts the control under the title, for wide controls such as the theme picker.
    public init(_ title: Text, detail: Text? = nil, stacked: Bool = false, @ViewBuilder control: () -> Control) {
        self.title = title
        self.detail = detail
        self.stacked = stacked
        self.control = control()
    }

    public var body: some View {
        Group {
            if stacked {
                VStack(alignment: .leading, spacing: 12) {
                    label
                    control
                }
            } else {
                HStack(alignment: .center, spacing: 23) {
                    label
                    Spacer(minLength: 0)
                    control
                }
            }
        }
        .padding(.vertical, 12)
        .frame(minHeight: 57)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var label: some View {
        VStack(alignment: .leading, spacing: 4) {
            title
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(PrismTheme.text)
            if let detail {
                detail
                    .font(.system(size: 11))
                    .foregroundStyle(PrismTheme.textMuted)
                    .lineSpacing(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: 420, alignment: .leading)
    }
}

public extension PrismSettingsRow where Control == EmptyView {
    init(_ title: Text, detail: Text? = nil) {
        self.init(title, detail: detail) { EmptyView() }
    }
}

/// Footnote text under a group.
public struct PrismSettingsNote: View {
    let text: Text
    public init(_ text: Text) {
        self.text = text
    }

    public var body: some View {
        text.font(.system(size: 11)).foregroundStyle(PrismTheme.textMuted).lineSpacing(2)
            .fixedSize(horizontal: false, vertical: true)
    }
}

// MARK: Command table

/// The table of commands with alias, hotkey and an enable switch (`.settings-command-table`).
/// Rows are separated by hairlines; the header names the columns.
public struct PrismCommandTable<Rows: View>: View {
    let rows: Rows
    let showsHeader: Bool
    let firstColumn: Text

    /// `firstColumn` names the first column ("Command", or "Layout" for window layouts).
    public init(showsHeader: Bool = true, firstColumn: Text? = nil, @ViewBuilder rows: () -> Rows) {
        self.showsHeader = showsHeader
        self.firstColumn = firstColumn ?? Text("Command", bundle: .module)
        self.rows = rows()
    }

    public var body: some View {
        VStack(spacing: 0) {
            if showsHeader {
                HStack(spacing: 12) {
                    firstColumn.padding(.leading, 49).frame(maxWidth: .infinity, alignment: .leading)
                    Text("Alias", bundle: .module).frame(width: PrismCommandRowMetrics.aliasWidth, alignment: .leading)
                    Text("Hotkey", bundle: .module).frame(width: PrismCommandRowMetrics.trailingWidth, alignment: .leading)
                }
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(PrismTheme.textMuted)
                .frame(height: 34)
                Rectangle().fill(PrismTheme.separator).frame(height: 1)
            }
            rows
        }
    }
}

public enum PrismCommandRowMetrics {
    public static let aliasWidth: CGFloat = 130
    public static let trailingWidth: CGFloat = 170
}

/// One command: glyph, name, alias field, hotkey and enable switch, followed by a hairline.
public struct PrismCommandRow<Glyph: View, Hotkey: View>: View {
    let title: String
    let detail: Text?
    let glyph: Glyph
    @Binding var alias: String
    let aliasDisabled: Bool
    let hotkey: Hotkey
    let isEnabled: Binding<Bool>?
    let switchLocked: Bool

    /// `switchLocked` shows the enable switch dimmed and fixed, for commands that cannot be turned off.
    public init(title: String, detail: Text? = nil, alias: Binding<String>, aliasDisabled: Bool = false,
                isEnabled: Binding<Bool>? = nil, switchLocked: Bool = false,
                @ViewBuilder glyph: () -> Glyph, @ViewBuilder hotkey: () -> Hotkey) {
        self.title = title
        self.detail = detail
        _alias = alias
        self.aliasDisabled = aliasDisabled
        self.isEnabled = isEnabled
        self.switchLocked = switchLocked
        self.glyph = glyph()
        self.hotkey = hotkey()
    }

    public var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                HStack(spacing: 12) {
                    glyph
                        .foregroundStyle(PrismTheme.textSecondary)
                        .frame(width: 27, height: 27)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(verbatim: title)
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(PrismTheme.text)
                            .lineLimit(1)
                        if let detail { detail.font(.system(size: 10.5)).foregroundStyle(PrismTheme.textMuted).lineLimit(1) }
                    }
                }
                .padding(.leading, 10)
                .frame(maxWidth: .infinity, alignment: .leading)
                TextField(text: $alias, prompt: Text("Add alias", bundle: .module)) { Text("Alias", bundle: .module) }
                    .labelsHidden()
                    .textFieldStyle(PrismTextFieldStyle(height: 31))
                    .font(.system(size: 11))
                    .frame(width: PrismCommandRowMetrics.aliasWidth)
                    .disabled(aliasDisabled)
                HStack(spacing: 5) {
                    hotkey
                    Spacer(minLength: 0)
                    if let isEnabled {
                        Toggle(isOn: isEnabled) { EmptyView() }.toggleStyle(.prism).labelsHidden().disabled(switchLocked)
                    }
                }
                .frame(width: PrismCommandRowMetrics.trailingWidth)
            }
            .frame(minHeight: 57)
            Rectangle().fill(PrismTheme.separator).frame(height: 1)
        }
    }
}
