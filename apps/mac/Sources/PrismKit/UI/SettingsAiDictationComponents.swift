import SwiftUI

// Pieces shared by the AI and Dictation settings and their model pickers, taken from the Tauri app's
// `.ai-current-model`, `.ai-section-heading`, `.usage-segments`, `.ai-picker-providers`, `.model-picker-dialog`
// and `.model-meter` rules. Monochrome throughout: the "accent" is the light grey of `PrismTheme.accent`.

// MARK: Current model

/// The "Current model" block: a 3 pt accent bar on the left, a small eyebrow, the model name and muted details,
/// with a trigger button on the right (`.ai-current-model`).
public struct PrismCurrentModelBlock<Trigger: View>: View {
    let eyebrow: Text
    let title: String
    let details: [String]
    let trigger: Trigger

    public init(eyebrow: Text, title: String, details: [String], @ViewBuilder trigger: () -> Trigger) {
        self.eyebrow = eyebrow
        self.title = title
        self.details = details
        self.trigger = trigger()
    }

    public var body: some View {
        HStack(alignment: .center, spacing: 20) {
            VStack(alignment: .leading, spacing: 6) {
                eyebrow
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(PrismTheme.accent)
                Text(verbatim: title)
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(PrismTheme.text)
                    .lineLimit(2)
                    .truncationMode(.middle)
                ForEach(details.indices, id: \.self) { index in
                    Text(verbatim: details[index])
                        .font(.system(size: 11))
                        .foregroundStyle(PrismTheme.textMuted)
                        .lineLimit(2)
                        .truncationMode(.middle)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            trigger.fixedSize()
        }
        .padding(.vertical, 3)
        .padding(.leading, 15)
        .overlay(alignment: .leading) {
            Rectangle().fill(PrismTheme.accent).frame(width: 3)
        }
    }
}

/// The label of a menu-like trigger: text and a small chevron (`.ai-settings-model-trigger`).
public struct PrismTriggerLabel: View {
    let title: Text
    let systemImage: String?

    public init(_ title: Text, systemImage: String? = nil) {
        self.title = title
        self.systemImage = systemImage
    }

    public var body: some View {
        HStack(spacing: 9) {
            if let systemImage { Image(systemName: systemImage).font(.system(size: 12)) }
            title.lineLimit(1).truncationMode(.middle)
            Spacer(minLength: 0)
            Image(systemName: "chevron.down").font(.system(size: 9, weight: .semibold)).opacity(0.75)
        }
    }
}

/// A raised trigger with a strong border, used for "Choose model" (`.ai-settings-model-trigger`).
public struct PrismTriggerButtonStyle: ButtonStyle {
    let fill: Bool
    /// `fill: false` gives the quieter in-card variant (`.ai-model-trigger` inside the dictation cards).
    public init(fill: Bool = true) {
        self.fill = fill
    }

    public func makeBody(configuration: Configuration) -> some View {
        PrismTriggerBody(configuration: configuration, fill: fill)
    }
}

struct PrismTriggerBody: View {
    let configuration: ButtonStyleConfiguration
    let fill: Bool
    @Environment(\.isEnabled) private var isEnabled
    @ViewState private var isHovered = false

    var body: some View {
        configuration.label
            .font(.system(size: 12, weight: fill ? .medium : .regular))
            .foregroundStyle(fill ? PrismTheme.text : PrismTheme.textSecondary)
            .padding(.horizontal, fill ? 12 : 10)
            .frame(minHeight: fill ? 34 : 32)
            .background(RoundedRectangle(cornerRadius: fill ? 8 : 7, style: .continuous)
                .fill(isHovered || configuration.isPressed ? PrismTheme.surfaceSelected : fill ? PrismTheme.surfaceStrong : PrismTheme.surface))
            .overlay(RoundedRectangle(cornerRadius: fill ? 8 : 7, style: .continuous)
                .strokeBorder(fill ? PrismTheme.lineStrong : PrismTheme.line))
            .contentShape(Rectangle())
            .opacity(isEnabled ? 1 : 0.45)
            .onHover { isHovered = $0 }
    }
}

// MARK: Headings

/// A 13 pt section title with a muted note or control on the right (`.ai-section-heading`).
public struct PrismSectionHeading<Accessory: View>: View {
    let title: Text
    let size: CGFloat
    let accessory: Accessory

    public init(_ title: Text, size: CGFloat = 13, @ViewBuilder accessory: () -> Accessory = { EmptyView() }) {
        self.title = title
        self.size = size
        self.accessory = accessory()
    }

    public var body: some View {
        HStack(alignment: .center, spacing: 8) {
            title
                .font(.system(size: size, weight: .semibold))
                .foregroundStyle(PrismTheme.text)
            Spacer(minLength: 8)
            accessory
                .font(.system(size: 11))
                .foregroundStyle(PrismTheme.textMuted)
        }
    }
}

/// A full-width hairline (`border-top: 1px solid var(--line)`).
public struct PrismHairline: View {
    public init() {}
    public var body: some View {
        Rectangle().fill(PrismTheme.separator).frame(height: 1).frame(maxWidth: .infinity)
    }
}

// MARK: Tabs

/// Small tabs in a sunken track (`.usage-segments`, `.ai-picker-providers`): a faint tray, the active tab raised.
public struct PrismPillTabs<Value: Hashable>: View {
    @Binding var selection: Value
    let options: [(value: Value, title: String)]
    let fontSize: CGFloat
    let expands: Bool

    /// `expands` stretches the tabs to fill the width, as the model picker's provider tabs do.
    public init(selection: Binding<Value>, options: [(value: Value, title: String)], fontSize: CGFloat = 11, expands: Bool = false) {
        _selection = selection
        self.options = options
        self.fontSize = fontSize
        self.expands = expands
    }

    public var body: some View {
        HStack(spacing: 3) {
            ForEach(options.indices, id: \.self) { index in
                let option = options[index]
                let active = option.value == selection
                Button {
                    selection = option.value
                } label: {
                    Text(verbatim: option.title)
                        .font(.system(size: fontSize, weight: active && expands ? .semibold : .regular))
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                        .foregroundStyle(active ? PrismTheme.text : PrismTheme.textMuted)
                        .padding(.horizontal, expands ? 10 : 9)
                        .frame(maxWidth: expands ? .infinity : nil)
                        .frame(height: expands ? 30 : 24)
                        .background(RoundedRectangle(cornerRadius: 5, style: .continuous)
                            .fill(active ? PrismTheme.surfaceSelected : .clear)
                            .shadow(color: .black.opacity(active && expands ? 0.12 : 0), radius: 2, y: 1))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(active ? .isSelected : [])
            }
        }
        .padding(3)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(PrismTheme.surface))
        .fixedSize(horizontal: !expands, vertical: true)
        .animation(.easeOut(duration: 0.16), value: selection)
    }
}

// MARK: Checkbox

/// A 16 pt square checkbox in the monochrome palette (`.ai-tool-setting input[type=checkbox]`).
public struct PrismCheckboxStyle: ToggleStyle {
    public init() {}

    public func makeBody(configuration: Configuration) -> some View {
        PrismCheckboxBody(configuration: configuration)
    }
}

struct PrismCheckboxBody: View {
    let configuration: ToggleStyleConfiguration
    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        HStack(spacing: 8) {
            configuration.label
            RoundedRectangle(cornerRadius: 4, style: .continuous)
                .fill(configuration.isOn ? PrismTheme.accent : PrismTheme.surfaceStrong)
                .overlay(RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .strokeBorder(configuration.isOn ? Color.clear : PrismTheme.lineStrong))
                .overlay {
                    if configuration.isOn {
                        Image(systemName: "checkmark").font(.system(size: 9, weight: .bold)).foregroundStyle(PrismTheme.panel)
                    }
                }
                .frame(width: 16, height: 16)
                .opacity(isEnabled ? 1 : 0.45)
                .contentShape(Rectangle())
                .onTapGesture { configuration.isOn.toggle() }
                .accessibilityAddTraits(.isButton)
        }
    }
}

public extension ToggleStyle where Self == PrismCheckboxStyle {
    static var prismCheckbox: PrismCheckboxStyle { PrismCheckboxStyle() }
}

// MARK: Model picker

/// The model picker surface (`.model-picker-dialog`): the dark panel, 18 pt padding and 8 pt rhythm.
public struct PrismPickerPanel<Content: View>: View {
    let content: Content

    public init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 8) { content }
            .padding(18)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(PrismTheme.panel)
            .foregroundStyle(PrismTheme.text)
    }
}

/// Picker title with a muted count, then refresh and close buttons (`.ai-section-heading` in the dialog).
public struct PrismPickerHeader: View {
    let title: Text
    let count: String?
    let refreshing: Bool
    let onRefresh: (() -> Void)?
    let onClose: (() -> Void)?
    let refreshDisabled: Bool

    public init(_ title: Text, count: String? = nil, refreshing: Bool = false, refreshDisabled: Bool = false,
                onRefresh: (() -> Void)? = nil, onClose: (() -> Void)? = nil) {
        self.title = title
        self.count = count
        self.refreshing = refreshing
        self.refreshDisabled = refreshDisabled
        self.onRefresh = onRefresh
        self.onClose = onClose
    }

    public var body: some View {
        HStack(alignment: .center, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                title.font(.system(size: 16, weight: .semibold)).foregroundStyle(PrismTheme.text)
                if let count { Text(verbatim: count).font(.system(size: 11)).foregroundStyle(PrismTheme.textMuted) }
            }
            Spacer(minLength: 8)
            if let onRefresh {
                Button(action: onRefresh) {
                    HStack(spacing: 6) {
                        Image(systemName: "arrow.clockwise").font(.system(size: 11, weight: .medium))
                            .rotationEffect(.degrees(refreshing ? 180 : 0))
                        Text(refreshing ? "Loading" : "Refresh", bundle: .module)
                    }
                }
                .buttonStyle(.prismGhost)
                .disabled(refreshDisabled)
            }
            if let onClose {
                Button(action: onClose) { Image(systemName: "xmark").font(.system(size: 12, weight: .medium)) }
                    .buttonStyle(.prismGhost)
                    .keyboardShortcut(.cancelAction)
                    .help(Text("Close model picker", bundle: .module))
                    .accessibilityLabel(Text("Close model picker", bundle: .module))
            }
        }
        .frame(minHeight: 28)
    }
}

/// The 40 pt search well with a magnifying glass (`.ai-model-search`).
public struct PrismSearchWell<Field: View>: View {
    let field: Field

    public init(@ViewBuilder field: () -> Field) {
        self.field = field()
    }

    public var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass").font(.system(size: 13)).foregroundStyle(PrismTheme.textMuted)
            field
                .textFieldStyle(.plain)
                .font(.system(size: 13))
                .foregroundStyle(PrismTheme.text)
        }
        .padding(.horizontal, 12)
        .frame(height: 40)
        .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(PrismTheme.surface))
        .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous).strokeBorder(PrismTheme.lineStrong))
    }
}

/// A five-step meter of 8×5 cells (`.model-meter`). Price fills in secondary text, speed in the accent.
public struct PrismMeter: View {
    public enum Kind: Sendable { case price, speed }
    let level: Int
    let kind: Kind

    public init(level: Int, kind: Kind) {
        self.level = level
        self.kind = kind
    }

    public var body: some View {
        HStack(spacing: 3) {
            ForEach(1...5, id: \.self) { index in
                RoundedRectangle(cornerRadius: 2, style: .continuous)
                    .fill(index <= level ? (kind == .price ? PrismTheme.textSecondary : PrismTheme.accent) : PrismTheme.lineStrong)
                    .frame(width: 8, height: 5)
            }
        }
        .accessibilityHidden(true)
    }
}

/// A picker row's background: hover and selection raise it, selection adds a 3 pt accent edge (`.model-catalog-row`).
public struct PrismPickerRowBackground: View {
    let highlighted: Bool
    let selected: Bool

    public init(highlighted: Bool, selected: Bool) {
        self.highlighted = highlighted
        self.selected = selected
    }

    public var body: some View {
        RoundedRectangle(cornerRadius: 7, style: .continuous)
            .fill(highlighted || selected ? PrismTheme.surfaceSelected : .clear)
            .overlay(alignment: .leading) {
                if selected {
                    UnevenRoundedRectangle(topLeadingRadius: 7, bottomLeadingRadius: 7, style: .continuous)
                        .fill(PrismTheme.accent).frame(width: 3)
                }
            }
    }
}
