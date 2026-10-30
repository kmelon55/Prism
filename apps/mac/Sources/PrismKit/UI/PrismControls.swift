import AppKit
import SwiftUI

// Monochrome controls from the Tauri settings (`styles.css`, `settingsPolish.css`, `settingsSelect.css`).
// Every feature uses these instead of the stock bordered/rounded styles so the whole app reads as one surface.

// MARK: Switch

/// The 32×19 capsule switch: a faint track when off, a light track with a dark knob when on.
public struct PrismSwitchStyle: ToggleStyle {
    public init() {}

    public func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 10) {
            configuration.label
            PrismSwitchTrack(isOn: configuration.isOn)
                .onTapGesture { configuration.isOn.toggle() }
                .accessibilityAddTraits(.isButton)
        }
    }
}

struct PrismSwitchTrack: View {
    let isOn: Bool
    @Environment(\.isEnabled) private var isEnabled
    @AppStorage(PrismHighlights.key) private var highlights = false

    var body: some View {
        let prism = highlights && isOn
        ZStack(alignment: isOn ? .trailing : .leading) {
            // Circular (not continuous) capsule ends: continuous corners leave square "ears" at 19 pt height.
            Capsule()
                .fill(prism ? Self.prismTrack : isOn ? Self.onTrack : PrismTheme.surfaceStrong)
                .overlay {
                    if prism {
                        Capsule().fill(PrismHighlights.pastel).overlay(Capsule().fill(PrismHighlights.gloss)).opacity(0.8)
                    }
                }
                .overlay(Capsule().strokeBorder(prism ? Color.white.opacity(0.125) : isOn ? Self.onTrack : PrismTheme.lineStrong))
            Circle()
                .fill(prism ? Color(hex: 0xF0F1F5) : isOn ? Self.onKnob : Self.offKnob)
                .frame(width: 13, height: 13)
                .shadow(color: .black.opacity(0.2), radius: 1, y: 1)
                .padding(.horizontal, 3)
        }
        .frame(width: 32, height: 19)
        .opacity(isEnabled ? 1 : 0.45)
        .animation(.spring(response: 0.26, dampingFraction: 0.86), value: isOn)
        .contentShape(Capsule())
    }

    static let onTrack = PrismTheme.dynamic(dark: 0xC2C2C2, light: 0x5E5E5E)
    static let prismTrack = PrismTheme.dynamic(dark: 0x96A8B7, light: 0x737373)
    static let onKnob = PrismTheme.dynamic(dark: 0x292929, light: 0xFFFFFF)
    static let offKnob = PrismTheme.dynamic(dark: 0xBDC2CB, light: 0xFFFFFF)
}

public extension ToggleStyle where Self == PrismSwitchStyle {
    static var prism: PrismSwitchStyle { PrismSwitchStyle() }
}

// MARK: Buttons

/// `.prism` is the quiet bordered button used everywhere; `.prismPrimary` adds weight for the main action;
/// `.prismGhost` is a borderless icon or text button.
public struct PrismButtonStyle: ButtonStyle {
    public enum Kind: Sendable { case secondary, primary, ghost, destructive }
    let kind: Kind

    public init(_ kind: Kind = .secondary) {
        self.kind = kind
    }

    public func makeBody(configuration: Configuration) -> some View {
        PrismButtonBody(configuration: configuration, kind: kind)
    }
}

/// Hover state lives in a view; a `ButtonStyle` cannot own state itself.
struct PrismButtonBody: View {
    typealias Kind = PrismButtonStyle.Kind
    let configuration: ButtonStyleConfiguration
    let kind: Kind
    @Environment(\.isEnabled) private var isEnabled
    @ViewState private var isHovered = false

    var body: some View {
        configuration.label
            .font(.system(size: 12, weight: kind == .primary ? .semibold : .medium))
            .lineLimit(1)
            .foregroundStyle(foreground)
            .padding(.horizontal, kind == .ghost ? 7 : 11)
            .frame(minHeight: kind == .ghost ? 26 : 30)
            .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(background(pressed: configuration.isPressed)))
            .prismHighlight(active: kind == .primary && isEnabled)
            .overlay(RoundedRectangle(cornerRadius: 7, style: .continuous).strokeBorder(border))
            .contentShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
            .opacity(isEnabled ? 1 : 0.45)
            .onHover { isHovered = $0 }
            .animation(.easeOut(duration: 0.18), value: isHovered)
    }

    private var foreground: Color {
        switch kind {
        case .primary: PrismTheme.text
        case .destructive: PrismTheme.danger
        case .ghost: isHovered ? PrismTheme.text : PrismTheme.textSecondary
        case .secondary: isHovered ? PrismTheme.text : PrismTheme.textSecondary
        }
    }

    private func background(pressed: Bool) -> Color {
        if pressed { return PrismTheme.surfaceSelected }
        switch kind {
        case .primary: return PrismTheme.surfaceSelected
        case .ghost: return isHovered ? PrismTheme.surfaceStrong : .clear
        case .secondary, .destructive: return isHovered ? PrismTheme.surfaceStrong : PrismTheme.surface
        }
    }

    private var border: Color {
        switch kind {
        case .ghost: .clear
        case .primary: PrismTheme.lineStrong
        case .secondary, .destructive: isHovered ? PrismTheme.lineStrong : PrismTheme.line
        }
    }
}

public extension ButtonStyle where Self == PrismButtonStyle {
    static var prism: PrismButtonStyle { PrismButtonStyle(.secondary) }
    static var prismPrimary: PrismButtonStyle { PrismButtonStyle(.primary) }
    static var prismGhost: PrismButtonStyle { PrismButtonStyle(.ghost) }
    static var prismDestructive: PrismButtonStyle { PrismButtonStyle(.destructive) }
}

// MARK: Text fields

/// A flat well with a faint border: alias inputs, API keys, folder names.
public struct PrismTextFieldStyle: TextFieldStyle {
    let height: CGFloat
    public init(height: CGFloat = 31) {
        self.height = height
    }

    public func _body(configuration: TextField<Self._Label>) -> some View {
        configuration
            .textFieldStyle(.plain)
            .font(.system(size: 12))
            .foregroundStyle(PrismTheme.text)
            .padding(.horizontal, 10)
            .frame(height: height)
            .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(PrismTheme.surface))
            .overlay(RoundedRectangle(cornerRadius: 7, style: .continuous).strokeBorder(PrismTheme.lineStrong))
    }
}

public extension TextFieldStyle where Self == PrismTextFieldStyle {
    static var prism: PrismTextFieldStyle { PrismTextFieldStyle() }
}

/// Multi-line prompt and note editors share the field look.
public struct PrismTextEditor: View {
    @Binding var text: String
    let minHeight: CGFloat

    public init(text: Binding<String>, minHeight: CGFloat = 96) {
        _text = text
        self.minHeight = minHeight
    }

    public var body: some View {
        TextEditor(text: $text)
            .font(.system(size: 12))
            .scrollContentBackground(.hidden)
            .padding(8)
            .frame(minHeight: minHeight)
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(PrismTheme.surface))
            .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(PrismTheme.lineStrong))
    }
}

// MARK: Select

/// A compact menu button (`.settings-select`): current value, a soft chevron, and a native menu of options
/// with a checkmark on the current one.
public struct PrismSelect<Value: Hashable>: View {
    @Binding var selection: Value
    let options: [(value: Value, title: String)]
    let minWidth: CGFloat?

    public init(selection: Binding<Value>, options: [(value: Value, title: String)], minWidth: CGFloat? = nil) {
        _selection = selection
        self.options = options
        self.minWidth = minWidth
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
            PrismSelectLabel(title: options.first { $0.value == selection }?.title ?? "", minWidth: minWidth)
        }
        .menuStyle(.button)
        .buttonStyle(PrismSelectButtonStyle())
        .menuIndicator(.hidden)
        .fixedSize()
    }
}

struct PrismSelectLabel: View {
    let title: String
    let minWidth: CGFloat?

    var body: some View {
        HStack(spacing: 12) {
            Text(verbatim: title).lineLimit(1)
            Spacer(minLength: 0)
            Image(systemName: "chevron.down").font(.system(size: 9, weight: .semibold)).opacity(0.65)
        }
        .frame(minWidth: minWidth)
    }
}

struct PrismSelectButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        PrismSelectBody(configuration: configuration)
    }
}

struct PrismSelectBody: View {
    let configuration: ButtonStyleConfiguration
    @ViewState private var isHovered = false
    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        configuration.label
            .font(.system(size: 12))
            .foregroundStyle(PrismTheme.textSecondary)
            .padding(.horizontal, 11)
            .frame(minHeight: 32)
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(isHovered || configuration.isPressed ? PrismTheme.surfaceStrong : PrismTheme.surface))
            .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(isHovered ? PrismTheme.lineStrong : PrismTheme.line))
            .contentShape(Rectangle())
            .opacity(isEnabled ? 1 : 0.45)
            .onHover { isHovered = $0 }
    }
}

// MARK: Segmented choice

/// The theme picker (`.theme-options`): equal-width options with an icon, a raised active option and a check.
public struct PrismSegmented<Value: Hashable>: View {
    @Binding var selection: Value
    let options: [(value: Value, title: String, systemImage: String?)]

    public init(selection: Binding<Value>, options: [(value: Value, title: String, systemImage: String?)]) {
        _selection = selection
        self.options = options
    }

    public var body: some View {
        HStack(spacing: 6) {
            ForEach(options.indices, id: \.self) { index in
                let option = options[index]
                let active = option.value == selection
                Button {
                    selection = option.value
                } label: {
                    HStack(spacing: 8) {
                        if let image = option.systemImage {
                            Image(systemName: image).font(.system(size: 12))
                        }
                        Text(verbatim: option.title).font(.system(size: 11.5, weight: .semibold))
                            .lineLimit(1).fixedSize()
                        Spacer(minLength: 0)
                        if active { Image(systemName: "checkmark").font(.system(size: 10, weight: .semibold)) }
                    }
                    .foregroundStyle(active ? PrismTheme.text : PrismTheme.textSecondary)
                    .padding(.horizontal, 11)
                    .frame(width: 112, height: 38)
                    .prismHighlight(active: active)
                    .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(active ? PrismTheme.surfaceSelected : .clear))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .animation(.easeOut(duration: 0.18), value: selection)
    }
}

// MARK: Slider

/// A 6 pt track with a light fill and an 18 pt glossy thumb, followed by the formatted value.
public struct PrismSlider: View {
    @AppStorage(PrismHighlights.key) private var highlights = false
    @Binding var value: Double
    let range: ClosedRange<Double>
    let step: Double?
    let width: CGFloat
    let format: (Double) -> String

    public init(value: Binding<Double>, in range: ClosedRange<Double>, step: Double? = nil, width: CGFloat = 180,
                format: @escaping (Double) -> String) {
        _value = value
        self.range = range
        self.step = step
        self.width = width
        self.format = format
    }

    public var body: some View {
        HStack(spacing: 18) {
            GeometryReader { proxy in
                let fraction = CGFloat((value - range.lowerBound) / (range.upperBound - range.lowerBound))
                let travel = proxy.size.width - 18
                ZStack(alignment: .leading) {
                    Capsule().fill(Self.track).frame(height: 6)
                    Capsule().fill(highlights ? AnyShapeStyle(PrismHighlights.pastel) : AnyShapeStyle(Self.fill))
                        .overlay { if highlights { Capsule().fill(PrismHighlights.gloss) } }
                        .frame(width: max(6, 9 + travel * fraction), height: 6)
                    Circle()
                        .fill(highlights ? AnyShapeStyle(PrismHighlights.thumb)
                              : AnyShapeStyle(LinearGradient(colors: [Self.thumbTop, Self.thumbBottom], startPoint: .topLeading, endPoint: .bottomTrailing)))
                        .overlay { if highlights { Circle().fill(RadialGradient(colors: [.white.opacity(0.63), .clear], center: UnitPoint(x: 0.3, y: 0.15), startRadius: 0, endRadius: 13)) } }
                        .overlay(Circle().strokeBorder(highlights ? Color.clear : Self.thumbBorder))
                        .frame(width: 18, height: 18)
                        .shadow(color: .black.opacity(0.21), radius: 2.5, y: 2)
                        .offset(x: travel * fraction)
                }
                .frame(maxHeight: .infinity)
                .contentShape(Rectangle())
                .gesture(DragGesture(minimumDistance: 0).onChanged { drag in
                    let raw = Double(min(max(0, (drag.location.x - 9) / travel), 1))
                    var next = range.lowerBound + raw * (range.upperBound - range.lowerBound)
                    if let step { next = (next / step).rounded() * step }
                    value = min(max(next, range.lowerBound), range.upperBound)
                })
            }
            .frame(width: width, height: 28)
            Text(verbatim: format(value))
                .font(.system(size: 11, weight: .medium))
                .monospacedDigit()
                .foregroundStyle(PrismTheme.textSecondary)
                .frame(minWidth: 30, alignment: .trailing)
        }
    }

    static let track = PrismTheme.dynamic(dark: 0xFFFFFF, darkAlpha: 0x16, light: 0x223541, lightAlpha: 0x18)
    static let fill = PrismTheme.dynamic(dark: 0xB4B4B4, light: 0x767676)
    static let thumbTop = PrismTheme.dynamic(dark: 0xF1F1F1, light: 0xFFFFFF)
    static let thumbBottom = PrismTheme.dynamic(dark: 0xCACACA, light: 0xE8E8E8)
    static let thumbBorder = PrismTheme.dynamic(dark: 0xFFFFFF, darkAlpha: 0x50, light: 0x000000, lightAlpha: 0x20)
}

// MARK: Badges and callouts

/// A small pill for states such as "Not required", "Granted" or a count.
public struct PrismBadge: View {
    public enum Tone: Sendable { case neutral, success, warning, danger }
    let text: String
    let tone: Tone

    public init(_ text: String, tone: Tone = .neutral) {
        self.text = text
        self.tone = tone
    }

    public var body: some View {
        HStack(spacing: 5) {
            if tone != .neutral { Circle().fill(color).frame(width: 5, height: 5) }
            Text(verbatim: text)
        }
        .font(.system(size: 10.5, weight: .semibold))
        .foregroundStyle(tone == .neutral ? PrismTheme.textSecondary : color)
        .padding(.horizontal, 8)
        .frame(height: 22)
        .background(Capsule().fill(PrismTheme.surface))
        .overlay(Capsule().strokeBorder(PrismTheme.line))
    }

    private var color: Color {
        switch tone {
        case .neutral: PrismTheme.textSecondary
        case .success: PrismTheme.success
        case .warning: PrismTheme.warning
        case .danger: PrismTheme.danger
        }
    }
}

/// A card with an icon tile, a title and a line of explanation (`.settings-callout`).
public struct PrismCallout<Accessory: View>: View {
    let systemImage: String
    let title: Text
    let detail: Text?
    let accessory: Accessory

    public init(systemImage: String, title: Text, detail: Text? = nil, @ViewBuilder accessory: () -> Accessory = { EmptyView() }) {
        self.systemImage = systemImage
        self.title = title
        self.detail = detail
        self.accessory = accessory()
    }

    public var body: some View {
        HStack(spacing: 12) {
            PrismIconTile(systemImage: systemImage)
            VStack(alignment: .leading, spacing: 3) {
                title.font(.system(size: 12, weight: .semibold)).foregroundStyle(PrismTheme.text)
                if let detail { detail.font(.system(size: 11)).foregroundStyle(PrismTheme.textMuted).fixedSize(horizontal: false, vertical: true) }
            }
            Spacer(minLength: 12)
            accessory
        }
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(PrismTheme.surface))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(PrismTheme.line))
    }
}

/// A 32 pt rounded tile holding a monochrome glyph.
public struct PrismIconTile: View {
    let systemImage: String
    let size: CGFloat

    public init(systemImage: String, size: CGFloat = 32) {
        self.systemImage = systemImage
        self.size = size
    }

    public var body: some View {
        Image(systemName: systemImage)
            .font(.system(size: size * 0.44))
            .foregroundStyle(PrismTheme.textSecondary)
            .frame(width: size, height: size)
            .background(RoundedRectangle(cornerRadius: size * 0.3, style: .continuous).fill(PrismTheme.surfaceSelected))
            .overlay(RoundedRectangle(cornerRadius: size * 0.3, style: .continuous).strokeBorder(PrismTheme.lineStrong))
    }
}

/// A rounded container for grouped rows (`--settings-card`).
public struct PrismCard<Content: View>: View {
    let padding: EdgeInsets
    let content: Content

    public init(padding: EdgeInsets = EdgeInsets(top: 4, leading: 16, bottom: 4, trailing: 16), @ViewBuilder content: () -> Content) {
        self.padding = padding
        self.content = content()
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 0) { content }
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(PrismTheme.surfaceStrong))
            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(PrismTheme.lineStrong))
    }
}

/// A disclosure with the small rotating chevron of `.animated-details`.
public struct PrismDisclosure<Content: View>: View {
    let title: Text
    let content: Content
    @ViewState private var isExpanded = false

    public init(_ title: Text, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Button {
                withAnimation(.timingCurve(0.22, 1, 0.36, 1, duration: 0.22)) { isExpanded.toggle() }
            } label: {
                HStack(spacing: 7) {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 8, weight: .bold))
                        .rotationEffect(.degrees(isExpanded ? 90 : 0))
                    title
                }
                .font(.system(size: 12))
                .foregroundStyle(PrismTheme.textSecondary)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            if isExpanded {
                content.transition(.opacity)
            }
        }
    }
}
