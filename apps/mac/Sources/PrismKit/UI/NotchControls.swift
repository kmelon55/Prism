import AppKit
import SwiftUI

/// AppKit resolves the template before it enters the shared toolbar's SwiftUI layer tree.
public struct NotchSymbol: View {
    let name: String
    let size: CGFloat
    public init(_ name: String, size: CGFloat = 18) { self.name = name; self.size = size }
    public var body: some View {
        Image(nsImage: NSImage(systemSymbolName: name, accessibilityDescription: nil) ?? NSImage())
            .renderingMode(.template).resizable().scaledToFit().frame(width: size, height: size)
            .accessibilityHidden(true)
    }
}

/// Compact controls shared by feature-owned notch views. Colors also adapt in a palette screen.
public struct NotchButtonStyle: ButtonStyle {
    public var prominent: Bool
    public var selected: Bool
    public init(prominent: Bool = false, selected: Bool = false) {
        self.prominent = prominent; self.selected = selected
    }
    public func makeBody(configuration: Configuration) -> some View {
        Surface(configuration: configuration, prominent: prominent, selected: selected)
    }
    private struct Surface: View {
        let configuration: ButtonStyle.Configuration
        let prominent: Bool
        let selected: Bool
        @Environment(\.isEnabled) private var enabled
        @ViewState private var hovering = false
        var body: some View {
            configuration.label
                .foregroundStyle(prominent ? Color.black : selected ? .orange : .primary)
                .background {
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(prominent ? Color.orange : selected ? .orange.opacity(0.14) : .primary.opacity(hovering ? 0.10 : 0.045))
                }
                .overlay {
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .strokeBorder(selected ? Color.orange.opacity(0.24) : .primary.opacity(hovering ? 0.12 : 0.04))
                }
                .opacity(!enabled ? 0.4 : configuration.isPressed ? 0.72 : 1)
                .contentShape(RoundedRectangle(cornerRadius: 10))
                .onHover { hovering = $0 }
        }
    }
}

public struct NotchIconButton: View {
    let symbol: String
    let label: String
    let selected: Bool
    let action: () -> Void
    public init(_ symbol: String, label: String, selected: Bool = false, action: @escaping () -> Void) {
        self.symbol = symbol; self.label = label; self.selected = selected; self.action = action
    }
    public var body: some View {
        Button(action: action) {
            NotchSymbol(symbol, size: 16).frame(width: 30, height: 30)
        }.buttonStyle(NotchButtonStyle(selected: selected)).help(label).accessibilityLabel(label)
    }
}

public struct NotchModePicker: View {
    let titles: [String]
    @Binding var selection: Int
    public init(_ titles: [String], selection: Binding<Int>) { self.titles = titles; self._selection = selection }
    public var body: some View {
        HStack(spacing: 3) {
            ForEach(titles.indices, id: \.self) { index in
                Button { selection = index } label: {
                    Text(titles[index]).font(.system(size: 11, weight: .medium))
                        .lineLimit(1).padding(.horizontal, 12).frame(height: 28)
                }
                .buttonStyle(NotchButtonStyle(selected: selection == index))
                .accessibilityAddTraits(selection == index ? .isSelected : [])
            }
        }.fixedSize(horizontal: true, vertical: false)
    }
}

public struct NotchEmptyState: View {
    let symbol: String
    let title: String
    let detail: String
    public init(_ symbol: String, title: String, detail: String = "") {
        self.symbol = symbol; self.title = title; self.detail = detail
    }
    public var body: some View {
        VStack(spacing: 9) {
            Image(systemName: symbol).font(.system(size: 24, weight: .light))
                .foregroundStyle(.orange.opacity(0.8)).frame(height: 34)
            Text(title).font(.system(size: 12, weight: .medium))
            if !detail.isEmpty { Text(detail).font(.system(size: 11)).foregroundStyle(.secondary).multilineTextAlignment(.center) }
        }.frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
