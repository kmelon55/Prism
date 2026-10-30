import AppKit
import SwiftUI

// Shared pieces of the launcher and the screens pushed inside it, measured from the Tauri app
// (`styles.css`, `surfaces.css`): the back arrow, the screen header, the 40-point status bar with separate
// key caps, the right-side ⌘K action panel, section labels, empty and loading states, and the library tabs.

/// Heights of the launcher chrome.
public enum PrismPaletteMetrics {
    /// The root search line (`.search-zone`).
    public static let searchHeight: CGFloat = 64
    /// The header of a pushed screen: back arrow, search field and trailing controls.
    public static let screenHeaderHeight: CGFloat = 54
    /// The status bar (`.statusbar`).
    public static let statusBarHeight: CGFloat = 40
    /// A result row (`.result-row`).
    public static let rowHeight: CGFloat = 38
}

public extension Font {
    /// The system font at a CSS weight (400 regular … 700 bold), so values such as 550 land between medium
    /// and semibold as they do in the Tauri app.
    static func prism(_ size: CGFloat, weight css: Int = 400) -> Font {
        let stops: [(Int, CGFloat)] = [(300, NSFont.Weight.light.rawValue), (400, NSFont.Weight.regular.rawValue),
                                       (500, NSFont.Weight.medium.rawValue), (600, NSFont.Weight.semibold.rawValue),
                                       (700, NSFont.Weight.bold.rawValue)]
        let clamped = min(max(css, 300), 700)
        var weight = NSFont.Weight.regular.rawValue
        for (index, stop) in stops.enumerated().dropLast() where clamped >= stop.0 {
            let next = stops[index + 1]
            let fraction = CGFloat(clamped - stop.0) / CGFloat(next.0 - stop.0)
            weight = stop.1 + (next.1 - stop.1) * min(fraction, 1)
        }
        return Font(NSFont.systemFont(ofSize: size, weight: NSFont.Weight(weight)))
    }
}

/// Line-glyph names: the Tauri app draws lucide outlines, so filled SF Symbols drop their fill when an
/// outline variant exists ("moon.fill" → "moon").
public enum PrismGlyph {
    @MainActor private static var cache: [String: String] = [:]

    @MainActor
    public static func outline(_ name: String) -> String {
        if let cached = cache[name] { return cached }
        var result = name
        if name.contains(".fill") {
            let stripped = name.replacingOccurrences(of: ".fill", with: "")
            if NSImage(systemSymbolName: stripped, accessibilityDescription: nil) != nil { result = stripped }
        }
        cache[name] = result
        return result
    }
}

// MARK: Buttons

/// The lucide-style back arrow at the start of every pushed screen (`.icon-button` with `ArrowLeft`).
public struct PrismBackButton: View {
    let help: Text?
    let action: () -> Void
    @ViewState private var hovering = false

    public init(help: Text? = nil, action: @escaping () -> Void) {
        self.help = help
        self.action = action
    }

    public var body: some View {
        Button(action: action) {
            Image(systemName: "arrow.left")
                .font(.system(size: 14, weight: .regular))
                .foregroundStyle(hovering ? PrismTheme.text : PrismTheme.textMuted)
                .frame(width: 28, height: 28)
                .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(hovering ? PrismTheme.surfaceStrong : .clear))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(help ?? Text(verbatim: ""))
        .accessibilityLabel(help ?? Text(verbatim: "Back"))
    }
}

/// A borderless 28-point icon button with a hover fill, for header tools such as preview or delete.
public struct PrismIconButton: View {
    let systemImage: String
    let help: Text?
    var isActive: Bool
    let action: () -> Void
    @Environment(\.isEnabled) private var isEnabled
    @ViewState private var hovering = false

    public init(systemImage: String, help: Text? = nil, isActive: Bool = false, action: @escaping () -> Void) {
        self.systemImage = systemImage
        self.help = help
        self.isActive = isActive
        self.action = action
    }

    public var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 14, weight: .regular))
                .foregroundStyle(hovering || isActive ? PrismTheme.text : PrismTheme.textSecondary)
                .frame(width: 30, height: 30)
                .background(RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(hovering || isActive ? PrismTheme.surfaceSelected : .clear))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .opacity(isEnabled ? 1 : 0.4)
        .onHover { hovering = $0 }
        .help(help ?? Text(verbatim: ""))
    }
}

// MARK: Header

/// The header of a screen pushed inside the palette: back arrow, search field and right-side controls on one
/// line, with a hairline below. Content is laid out in an `HStack` with 10 points between items.
public struct PrismScreenHeader<Content: View>: View {
    let height: CGFloat
    let content: Content

    public init(height: CGFloat = PrismPaletteMetrics.screenHeaderHeight, @ViewBuilder content: () -> Content) {
        self.height = height
        self.content = content()
    }

    public var body: some View {
        HStack(spacing: 10) { content }
            .padding(.horizontal, 16)
            .frame(height: height)
            .overlay(alignment: .bottom) { PrismRule() }
    }
}

/// The magnifier that leads a screen's search field.
public struct PrismSearchGlyph: View {
    public init() {}

    public var body: some View {
        Image(systemName: "magnifyingglass")
            .font(.system(size: 13, weight: .regular))
            .foregroundStyle(PrismTheme.textMuted)
            .frame(width: 18)
    }
}

/// A one-point `--line` rule.
public struct PrismRule: View {
    var strong: Bool

    public init(strong: Bool = false) {
        self.strong = strong
    }

    public var body: some View {
        Rectangle().fill(strong ? PrismTheme.lineStrong : PrismTheme.line).frame(height: 1)
    }
}

/// A vertical `--line` rule, for split panes.
public struct PrismVerticalRule: View {
    public init() {}

    public var body: some View {
        Rectangle().fill(PrismTheme.line).frame(width: 1)
    }
}

// MARK: Status bar

/// The 40-point bar at the bottom of the palette and its screens: leading controls, then trailing actions.
public struct PrismStatusBar<Leading: View, Trailing: View>: View {
    let leading: Leading
    let trailing: Trailing

    public init(@ViewBuilder leading: () -> Leading, @ViewBuilder trailing: () -> Trailing) {
        self.leading = leading()
        self.trailing = trailing()
    }

    public var body: some View {
        HStack(spacing: 8) {
            leading
            Spacer(minLength: 12)
            trailing
        }
        .font(.prism(11, weight: 500))
        .foregroundStyle(PrismTheme.textMuted)
        .padding(.horizontal, 16)
        .frame(height: PrismPaletteMetrics.statusBarHeight)
        .overlay(alignment: .top) { PrismRule() }
    }
}

/// A borderless status bar button that lights up on hover or while its panel is open (`.statusbar-button`).
public struct PrismStatusButton<Label: View>: View {
    let isActive: Bool
    let tint: Color
    let action: () -> Void
    let label: Label
    @Environment(\.isEnabled) private var isEnabled
    @ViewState private var hovering = false

    /// - Parameter tint: The resting text color; hover and `isActive` brighten it to `PrismTheme.text`.
    public init(isActive: Bool = false, tint: Color = PrismTheme.textMuted, action: @escaping () -> Void, @ViewBuilder label: () -> Label) {
        self.isActive = isActive
        self.tint = tint
        self.action = action
        self.label = label()
    }

    public var body: some View {
        Button(action: action) {
            label
                .padding(.horizontal, 7)
                .frame(minHeight: 28)
                .background(RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill((hovering && isEnabled) || isActive ? PrismTheme.surfaceStrong : .clear))
                .foregroundStyle((hovering && isEnabled) || isActive ? PrismTheme.text : tint)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .opacity(isEnabled ? 1 : 0.4)
        .onHover { hovering = $0 }
    }
}

/// A status bar action: its title and key caps, such as "Copy ↵" or "Actions ⌘ K".
public struct PrismStatusAction: View {
    let title: Text
    let keys: String
    let isPrimary: Bool
    let isActive: Bool
    let action: () -> Void

    public init(_ title: Text, keys: String, isPrimary: Bool = false, isActive: Bool = false, action: @escaping () -> Void) {
        self.title = title
        self.keys = keys
        self.isPrimary = isPrimary
        self.isActive = isActive
        self.action = action
    }

    public var body: some View {
        PrismStatusButton(isActive: isActive, tint: isPrimary ? PrismTheme.textSecondary : PrismTheme.textMuted, action: action) {
            HStack(spacing: 6) {
                title
                    .lineLimit(1)
                    .truncationMode(.tail)
                PrismShortcutCaps(keys)
            }
        }
    }
}

/// The 14-point rule between the primary action and "Actions".
public struct PrismStatusDivider: View {
    public init() {}

    public var body: some View {
        Rectangle().fill(PrismTheme.lineStrong).frame(width: 1, height: 14).padding(.horizontal, 1)
    }
}

/// A shortcut as separate caps: "⌘K" draws ⌘ and K in their own caps, like the Tauri `Shortcut`.
public struct PrismShortcutCaps: View {
    let parts: [String]

    public init(_ keys: String) {
        parts = Self.split(keys)
    }

    public var body: some View {
        HStack(spacing: 3) {
            ForEach(Array(parts.enumerated()), id: \.offset) { _, part in
                KeyCap(part)
            }
        }
    }

    /// Modifier symbols get their own caps; the rest stays one cap ("esc", "↑↓", "F5").
    static func split(_ keys: String) -> [String] {
        let modifiers: Set<Character> = ["⌃", "⌥", "⇧", "⌘"]
        var parts: [String] = []
        var rest = ""
        for character in keys {
            if modifiers.contains(character), rest.isEmpty {
                parts.append(String(character))
            } else {
                rest.append(character)
            }
        }
        if !rest.isEmpty { parts.append(rest) }
        return parts
    }
}

// MARK: Lists

/// A result section title (`.result-section-label`).
public struct PrismSectionLabel: View {
    let title: String
    let isFirst: Bool

    public init(_ title: String, isFirst: Bool = false) {
        self.title = title
        self.isFirst = isFirst
    }

    public var body: some View {
        Text(verbatim: title)
            .font(.prism(10, weight: 600))
            .tracking(0.15)
            .foregroundStyle(PrismTheme.textMuted)
            .lineLimit(1)
            .padding(.horizontal, 11)
            .padding(.top, isFirst ? 6 : 8)
            .padding(.bottom, 4)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

public extension View {
    /// The selected row's soft gradient (`--selection`) with the row radius.
    func prismRowBackground(isSelected: Bool, cornerRadius: CGFloat = 7) -> some View {
        background {
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .fill(isSelected ? AnyShapeStyle(PrismTheme.selection) : AnyShapeStyle(Color.clear))
        }
    }
}

/// The centered empty state (`.empty-state`): a dashed circle, a title and one line of help.
public struct PrismEmptyState: View {
    let symbol: String
    let title: Text
    let message: Text?
    let button: (title: Text, action: () -> Void)?

    public init(symbol: String = "circle.dashed", title: Text, message: Text? = nil, button: (title: Text, action: () -> Void)? = nil) {
        self.symbol = symbol
        self.title = title
        self.message = message
        self.button = button
    }

    public var body: some View {
        VStack(spacing: 8) {
            Image(systemName: symbol)
                .font(.system(size: 21, weight: .light))
                .foregroundStyle(PrismTheme.textMuted)
            title
                .font(.prism(12.5, weight: 600))
                .foregroundStyle(PrismTheme.textSecondary)
                .padding(.top, 6)
                .multilineTextAlignment(.center)
            if let message {
                message
                    .font(.prism(12, weight: 500))
                    .foregroundStyle(PrismTheme.textMuted)
                    .multilineTextAlignment(.center)
                    .lineSpacing(3)
                    .frame(maxWidth: 290)
            }
            if let button {
                Button(action: button.action) { button.title }
                    .buttonStyle(.prism)
                    .padding(.top, 6)
            }
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// Four pulsing placeholder rows while results load (`.loading-state`).
public struct PrismLoadingRows: View {
    @ViewState private var dimmed = false

    public init() {}

    public var body: some View {
        VStack(spacing: 7) {
            ForEach([1.0, 0.75, 0.56, 0.4], id: \.self) { opacity in
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .fill(PrismTheme.surfaceStrong)
                    .frame(height: 43)
                    .opacity(opacity)
            }
        }
        .opacity(dimmed ? 0.42 : 1)
        .padding(.horizontal, 9)
        .padding(.vertical, 31)
        .frame(maxHeight: .infinity, alignment: .top)
        .onAppear {
            guard !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else { return }
            withAnimation(.easeInOut(duration: 1.3).repeatForever(autoreverses: true)) { dimmed = true }
        }
    }
}

// MARK: Action panel

/// The ⌘K panel: a floating sheet on the right over a dimmed, blurred list, with a back arrow, the item's
/// title, an optional "Search actions…" field and one row per action. Place it over the content area between
/// the header and the status bar, and blur that content with `prismActionPanelBlur(_:)`.
public struct PrismActionPanel: View {
    let title: String
    let actions: [PaletteAction]
    let selection: Int
    let query: Binding<String>?
    let searchPrompt: String
    let emptyText: String
    let onMove: (Int) -> Void
    let onSelect: (Int) -> Void
    let onDismiss: () -> Void
    @FocusState private var searchFocused: Bool

    /// - Parameters:
    ///   - query: When set, the panel shows a search field bound to it and takes focus; the caller filters
    ///     `actions`. Arrows call `onMove` and Return calls `onSelect` with the selection.
    public init(title: String, actions: [PaletteAction], selection: Int, query: Binding<String>? = nil,
                searchPrompt: String? = nil, emptyText: String? = nil,
                onMove: @escaping (Int) -> Void = { _ in }, onSelect: @escaping (Int) -> Void, onDismiss: @escaping () -> Void) {
        self.title = title
        self.actions = actions
        self.selection = selection
        self.query = query
        self.searchPrompt = searchPrompt ?? String(localized: "Search actions…", bundle: .module)
        self.emptyText = emptyText ?? String(localized: "No matching actions", bundle: .module)
        self.onMove = onMove
        self.onSelect = onSelect
        self.onDismiss = onDismiss
    }

    public var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .trailing) {
                Color.black.opacity(0.34)
                    .contentShape(Rectangle())
                    .onTapGesture(perform: onDismiss)
                panel
                    .frame(width: min(370, max(proxy.size.width * 0.45, 300)))
                    .padding(9)
            }
        }
        .transition(.opacity)
    }

    private var panel: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                PrismBackButton(help: Text("Close actions", bundle: .module), action: onDismiss)
                Text(verbatim: title)
                    .font(.prism(12, weight: 600))
                    .foregroundStyle(PrismTheme.textSecondary)
                    .lineLimit(1)
            }
            .padding(15)
            .frame(maxWidth: .infinity, alignment: .leading)
            .overlay(alignment: .bottom) { PrismRule() }
            if let query {
                TextField(text: query, prompt: Text(verbatim: searchPrompt).foregroundStyle(PrismTheme.textMuted)) {
                    Text(verbatim: searchPrompt)
                }
                .textFieldStyle(.plain)
                .font(.prism(13))
                .foregroundStyle(PrismTheme.text)
                .focused($searchFocused)
                .onSubmit { onSelect(selection) }
                .onKeyPress(.downArrow) { onMove(1); return .handled }
                .onKeyPress(.upArrow) { onMove(-1); return .handled }
                .onKeyPress(phases: .down) { press in
                    guard press.modifiers == .control else { return .ignored }
                    if press.key == "n" { onMove(1); return .handled }
                    if press.key == "p" { onMove(-1); return .handled }
                    return .ignored
                }
                .padding(.horizontal, 10)
                .frame(height: 34)
                .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(PrismTheme.surface))
                .overlay(RoundedRectangle(cornerRadius: 7, style: .continuous).strokeBorder(PrismTheme.lineStrong))
                .padding(.horizontal, 12)
                .padding(.top, 10)
                .onAppear { searchFocused = true }
            }
            ScrollViewReader { scroll in
                ScrollView {
                    VStack(spacing: 3) {
                        ForEach(Array(actions.enumerated()), id: \.element.id) { index, action in
                            row(action, index: index).id(index)
                        }
                        if actions.isEmpty {
                            Text(verbatim: emptyText)
                                .font(.prism(12))
                                .foregroundStyle(PrismTheme.textSecondary)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(10)
                        }
                    }
                    .padding(9)
                }
                .scrollIndicators(.never)
                .onChange(of: selection) { _, selection in scroll.scrollTo(selection) }
            }
        }
        .frame(maxHeight: .infinity, alignment: .top)
        .background(PrismTheme.panel, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(PrismTheme.lineStrong))
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .shadow(color: .black.opacity(0.2), radius: 32, y: 12)
        .shadow(color: .black.opacity(0.1), radius: 8, y: 2)
        .contentShape(Rectangle())
        .onTapGesture {}
    }

    private func row(_ action: PaletteAction, index: Int) -> some View {
        let active = index == selection
        return HStack(spacing: 10) {
            Text(verbatim: action.title)
                .font(.prism(12, weight: 500))
                .lineLimit(1)
            Spacer(minLength: 12)
            if let shortcut = action.shortcut, index != 0 {
                PrismShortcutCaps(shortcut.displayText)
                    .opacity(active ? 1 : 0.7)
            }
        }
        .foregroundStyle(action.isDestructive ? PrismTheme.danger : (active ? PrismTheme.text : PrismTheme.textSecondary))
        .padding(.horizontal, 10)
        .frame(minHeight: 41)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(active ? PrismTheme.surfaceStrong : .clear))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(active ? PrismTheme.line : .clear))
        .contentShape(Rectangle())
        .onTapGesture { onSelect(index) }
    }
}

public extension View {
    /// Softens the list behind an open action panel (`backdrop-filter: blur(5px)`).
    func prismActionPanelBlur(_ isOpen: Bool) -> some View {
        blur(radius: isOpen ? 2.5 : 0)
            .animation(.easeOut(duration: 0.13), value: isOpen)
    }
}

// MARK: Tabs

/// The library tab strip (`.library-tabs`): quiet text tabs with a raised, bordered selected tab.
public struct PrismTabStrip<Value: Hashable>: View {
    let tabs: [(value: Value, title: String)]
    @Binding var selection: Value

    public init(_ tabs: [(value: Value, title: String)], selection: Binding<Value>) {
        self.tabs = tabs
        _selection = selection
    }

    public var body: some View {
        HStack(spacing: 6) {
            ForEach(Array(tabs.enumerated()), id: \.offset) { _, tab in
                PrismTabButton(title: tab.title, isSelected: tab.value == selection) { selection = tab.value }
            }
        }
    }
}

private struct PrismTabButton: View {
    let title: String
    let isSelected: Bool
    let action: () -> Void
    @ViewState private var hovering = false

    var body: some View {
        Button(action: action) {
            Text(verbatim: title)
                .font(.prism(12))
                .foregroundStyle(isSelected || hovering ? PrismTheme.text : PrismTheme.textSecondary)
                .padding(.horizontal, 12)
                .padding(.vertical, 7)
                .background {
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .fill(isSelected ? PrismTheme.control : (hovering ? PrismTheme.surface : .clear))
                        .shadow(color: .black.opacity(isSelected ? 0.05 : 0), radius: 1, y: 1)
                }
                .overlay(RoundedRectangle(cornerRadius: 7, style: .continuous).strokeBorder(isSelected ? PrismTheme.lineStrong : .clear))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .focusable(false)
        .onHover { hovering = $0 }
    }
}
