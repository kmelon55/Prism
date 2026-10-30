import SwiftUI

// Components for the Window Management, Clipboard, Backup & Restore and Permissions settings panes.

// MARK: Command aliases and hotkeys from feature panes

/// The shell's command aliases and hotkeys, offered to feature settings panes so they can show a command row
/// (alias field, hotkey recorder, enable switch) for their own commands, as the Tauri settings do.
///
/// The shell installs this once at launch in `PrismCommandSettings.access`. Reads that touch `@Observable`
/// stores inside these closures are tracked by SwiftUI, so rows update when the stores change.
public struct PrismCommandAccess {
    public var alias: @MainActor (String) -> String
    public var setAlias: @MainActor (String, String) -> Void
    /// True when the alias file exists but cannot be read, so aliases cannot be edited.
    public var aliasesLocked: @MainActor () -> Bool
    public var shortcut: @MainActor (String) -> Shortcut?
    public var setShortcut: @MainActor (String, Shortcut?) -> Void
    /// A localized message when the command's hotkey could not be registered, such as "Used by macOS or another app".
    public var shortcutProblem: @MainActor (String) -> String?
    /// Whether a command is enabled, or `nil` when the shell does not support disabling commands. When `nil`,
    /// rows show no enable switch.
    public var isEnabled: (@MainActor (String) -> Bool)?
    public var setEnabled: (@MainActor (String, Bool) -> Void)?

    public init(alias: @escaping @MainActor (String) -> String,
                setAlias: @escaping @MainActor (String, String) -> Void,
                aliasesLocked: @escaping @MainActor () -> Bool = { false },
                shortcut: @escaping @MainActor (String) -> Shortcut?,
                setShortcut: @escaping @MainActor (String, Shortcut?) -> Void,
                shortcutProblem: @escaping @MainActor (String) -> String? = { _ in nil },
                isEnabled: (@MainActor (String) -> Bool)? = nil,
                setEnabled: (@MainActor (String, Bool) -> Void)? = nil) {
        self.alias = alias
        self.setAlias = setAlias
        self.aliasesLocked = aliasesLocked
        self.shortcut = shortcut
        self.setShortcut = setShortcut
        self.shortcutProblem = shortcutProblem
        self.isEnabled = isEnabled
        self.setEnabled = setEnabled
    }
}

@MainActor
public enum PrismCommandSettings {
    /// Installed by the app shell. While `nil` (tests, snapshots of a single module) command rows are read-only.
    public static var access: PrismCommandAccess?
}

/// A `PrismCommandRow` wired to the shell's aliases and hotkeys through `PrismCommandSettings.access`.
public struct PrismCommandShortcutRow<Glyph: View>: View {
    let commandID: String
    let title: String
    let glyph: Glyph

    public init(commandID: String, title: String, @ViewBuilder glyph: () -> Glyph) {
        self.commandID = commandID
        self.title = title
        self.glyph = glyph()
    }

    public var body: some View {
        let access = PrismCommandSettings.access
        let problem = access?.shortcutProblem(commandID)
        let enabled = access?.isEnabled?(commandID) ?? true
        PrismCommandRow(
            title: title,
            detail: problem.map { Text(verbatim: $0).foregroundStyle(PrismTheme.danger) },
            alias: Binding(get: { access?.alias(commandID) ?? "" }, set: { access?.setAlias($0, commandID) }),
            aliasDisabled: access == nil || access?.aliasesLocked() == true,
            isEnabled: access?.isEnabled == nil ? nil : Binding(
                get: { access?.isEnabled?(commandID) ?? true },
                set: { access?.setEnabled?(commandID, $0) }
            ),
            glyph: { glyph }
        ) {
            ShortcutRecorder(shortcut: Binding(get: { access?.shortcut(commandID) }, set: { access?.setShortcut(commandID, $0) }))
                .disabled(access == nil || !enabled)
        }
    }
}

// MARK: Checkbox

/// The monochrome checkbox of the Tauri backup categories (`accent-color: var(--text)`): a 14 pt rounded
/// square, filled light grey with a dark check when on.
public struct PrismLeadingCheckboxStyle: ToggleStyle {
    public init() {}

    public func makeBody(configuration: Configuration) -> some View {
        PrismLeadingCheckboxBody(configuration: configuration)
    }
}

struct PrismLeadingCheckboxBody: View {
    let configuration: ToggleStyleConfiguration
    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        Button {
            configuration.isOn.toggle()
        } label: {
            HStack(spacing: 8) {
                ZStack {
                    RoundedRectangle(cornerRadius: 3.5, style: .continuous)
                        .fill(configuration.isOn ? Self.checkedFill : PrismTheme.surfaceStrong)
                    RoundedRectangle(cornerRadius: 3.5, style: .continuous)
                        .strokeBorder(configuration.isOn ? Self.checkedFill : Self.border)
                    if configuration.isOn {
                        Image(systemName: "checkmark")
                            .font(.system(size: 8.5, weight: .heavy))
                            .foregroundStyle(Self.check)
                    }
                }
                .frame(width: 14, height: 14)
                configuration.label
                    .font(.system(size: 12))
                    .foregroundStyle(PrismTheme.text)
            }
            .contentShape(Rectangle())
            .opacity(isEnabled ? 1 : 0.45)
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(configuration.isOn ? [.isSelected] : [])
    }

    static let checkedFill = PrismTheme.dynamic(dark: 0xB4B4B4, light: 0x5E5E5E)
    static let check = PrismTheme.dynamic(dark: 0x1E1E1E, light: 0xFFFFFF)
    static let border = PrismTheme.dynamic(dark: 0xFFFFFF, darkAlpha: 0x30, light: 0x000000, lightAlpha: 0x30)
}

public extension ToggleStyle where Self == PrismLeadingCheckboxStyle {
    static var prismLeadingCheckbox: PrismLeadingCheckboxStyle { PrismLeadingCheckboxStyle() }
}

// MARK: Status pill

/// The permission status pill (`.permission-status`): a 27 pt capsule with a 7 pt colored dot and secondary text.
/// Only the dot carries color, except `success`, whose text is green as in the Tauri app.
public struct PrismStatusPill: View {
    public enum Tone: Sendable { case neutral, success, warning, danger }
    let text: String
    let tone: Tone

    public init(_ text: String, tone: Tone) {
        self.text = text
        self.tone = tone
    }

    public var body: some View {
        HStack(spacing: 7) {
            Circle().fill(dot).frame(width: 7, height: 7)
            Text(verbatim: text)
        }
        .font(.system(size: 11, weight: .semibold))
        .foregroundStyle(tone == .success ? Self.successText : PrismTheme.textSecondary)
        .padding(.horizontal, 10)
        .frame(height: 27)
        .overlay(Capsule().strokeBorder(PrismTheme.lineStrong))
        .fixedSize()
    }

    private var dot: Color {
        switch tone {
        case .neutral: PrismTheme.textMuted
        case .success: Self.successDot
        case .warning: Self.warningDot
        case .danger: PrismTheme.danger
        }
    }

    static let successDot = PrismTheme.dynamic(dark: 0x64C77F, light: 0x2F9A52)
    static let successText = PrismTheme.dynamic(dark: 0x84D79A, light: 0x257942)
    static let warningDot = PrismTheme.dynamic(dark: 0xD59B4E, light: 0xB87A2A)
}

// MARK: Card row

/// One setting inside a settings card (`.preference-section.compact` on a card): title and explanation on a
/// narrow left column, the control filling the right, 17 pt padding. Used by the clipboard settings.
public struct PrismCardSetting<Detail: View, Control: View>: View {
    let title: Text
    let detail: Detail
    let control: Control
    let labelWidth: CGFloat

    public init(_ title: Text, labelWidth: CGFloat = 190, @ViewBuilder detail: () -> Detail, @ViewBuilder control: () -> Control) {
        self.title = title
        self.labelWidth = labelWidth
        self.detail = detail()
        self.control = control()
    }

    public var body: some View {
        HStack(alignment: .center, spacing: 32) {
            VStack(alignment: .leading, spacing: 5) {
                title
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(PrismTheme.text)
                VStack(alignment: .leading, spacing: 5) { detail }
                    .font(.system(size: 11))
                    .foregroundStyle(PrismTheme.textMuted)
                    .lineSpacing(2.5)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(width: labelWidth, alignment: .leading)
            control
                .frame(maxWidth: .infinity, alignment: .trailing)
        }
        .padding(17)
        .frame(maxWidth: .infinity, alignment: .leading)
        .prismSettingsCard(cornerRadius: 12)
    }
}

/// A full-width menu select for card settings: the `PrismSelect` look stretched to fill its column.
public struct PrismWideSelect<Value: Hashable>: View {
    @Binding var selection: Value
    let options: [(value: Value, title: String)]

    public init(selection: Binding<Value>, options: [(value: Value, title: String)]) {
        _selection = selection
        self.options = options
    }

    public var body: some View {
        Menu {
            ForEach(options.indices, id: \.self) { index in
                let option = options[index]
                Button {
                    selection = option.value
                } label: {
                    if option.value == selection {
                        Label(option.title, systemImage: "checkmark")
                    } else {
                        Text(verbatim: option.title)
                    }
                }
            }
        } label: {
            PrismSelectLabel(title: options.first { $0.value == selection }?.title ?? "", minWidth: nil)
                .frame(maxWidth: .infinity)
        }
        .menuStyle(.button)
        .buttonStyle(PrismSelectButtonStyle())
        .menuIndicator(.hidden)
        .frame(maxWidth: .infinity)
    }
}

// MARK: Settings card surface

public extension View {
    /// The `--settings-card` surface (white 5 % with a hairline) behind window options, clipboard cards and the
    /// permission summary. A touch stronger than `PrismCard`, as in the Tauri screenshots.
    func prismSettingsCard(cornerRadius: CGFloat = 14) -> some View {
        background(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous).fill(PrismSettingsCardStyle.fill))
            .overlay(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous).strokeBorder(PrismSettingsCardStyle.border))
    }
}

enum PrismSettingsCardStyle {
    static let fill = PrismTheme.dynamic(dark: 0xFFFFFF, darkAlpha: 0x0D, light: 0xFFFFFF, lightAlpha: 0xB0)
    static let border = PrismTheme.dynamic(dark: 0xFFFFFF, darkAlpha: 0x0D, light: 0x000000, lightAlpha: 0x10)
}

// MARK: Flow layout

/// Lays children out left to right and wraps to a new line when the width runs out, like a CSS `flex-wrap`
/// row (backup categories, permission actions).
public struct PrismFlowLayout: Layout {
    let horizontalSpacing: CGFloat
    let verticalSpacing: CGFloat

    public init(horizontalSpacing: CGFloat = 20, verticalSpacing: CGFloat = 12) {
        self.horizontalSpacing = horizontalSpacing
        self.verticalSpacing = verticalSpacing
    }

    public func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let rows = arrange(width: proposal.width ?? .infinity, subviews: subviews)
        let width = rows.map { $0.width }.max() ?? 0
        let height = rows.reduce(0) { $0 + $1.height } + verticalSpacing * CGFloat(max(0, rows.count - 1))
        return CGSize(width: proposal.width ?? width, height: height)
    }

    public func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var y = bounds.minY
        for row in arrange(width: bounds.width, subviews: subviews) {
            var x = bounds.minX
            for index in row.indices {
                let size = subviews[index].sizeThatFits(.unspecified)
                subviews[index].place(at: CGPoint(x: x, y: y + (row.height - size.height) / 2), proposal: ProposedViewSize(size))
                x += size.width + horizontalSpacing
            }
            y += row.height + verticalSpacing
        }
    }

    private struct Row {
        var indices: [Int] = []
        var width: CGFloat = 0
        var height: CGFloat = 0
    }

    private func arrange(width: CGFloat, subviews: Subviews) -> [Row] {
        var rows: [Row] = []
        var current = Row()
        for index in subviews.indices {
            let size = subviews[index].sizeThatFits(.unspecified)
            let needed = current.indices.isEmpty ? size.width : current.width + horizontalSpacing + size.width
            if needed > width, !current.indices.isEmpty {
                rows.append(current)
                current = Row()
            }
            current.width = current.indices.isEmpty ? size.width : current.width + horizontalSpacing + size.width
            current.height = max(current.height, size.height)
            current.indices.append(index)
        }
        if !current.indices.isEmpty { rows.append(current) }
        return rows
    }
}
