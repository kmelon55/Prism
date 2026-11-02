import AppKit
import PrismKit
import SwiftUI

/// Settings on the left, the live notch on the right.
struct NotchSettingsView: View {
    @Bindable var model: NotchModel
    @ViewState private var screens = NotchDisplay.connected()
    @ViewState private var dragging: String?

    var body: some View {
        PrismSettingsPage(N("Notch")) {
            PrismSettingsGroup {
                PrismSettingsRow(Text(N("Show notch")), detail: Text(N("Keep your favorite tools at the top of the screen."))) {
                    Toggle(isOn: Binding(get: { model.preferences.enabled }, set: { model.setEnabled($0) })) { EmptyView() }
                        .toggleStyle(.prism).labelsHidden().accessibilityLabel(N("Show notch"))
                }
                PrismSettingsRow(Text(N("Preview on hover")), detail: Text(N("Hover for a preview. Click to open, then pin to keep it open."))) {
                    Toggle(isOn: Binding(get: { model.preferences.hoverPreview }, set: { value in model.change { $0.hoverPreview = value } })) { EmptyView() }
                        .toggleStyle(.prism).labelsHidden().accessibilityLabel(N("Preview on hover"))
                }
            }
            PrismSettingsGroup(Text(N("Pinned tools")), accessory: {
                Text(String(format: N("%lld pinned"), Int64(model.visibleIDs.count)))
                    .font(.system(size: 10.5)).foregroundStyle(PrismTheme.textMuted)
            }) {
                ForEach(orderedIDs, id: \.self) { id in toolRow(id) }
            }
            PrismSettingsNote(Text(N("These tools use your existing Prism data. Clipboard capture stays under Clipboard settings.")))
            PrismSettingsGroup(Text(N("Displays"))) {
                PrismSettingsRow(Text(N("All displays")), detail: Text(N("Also shows the notch on displays connected later."))) {
                    Toggle(isOn: Binding(get: { model.preferences.displays.mode == .all }, set: { enabled in
                        model.change { $0.displays = NotchDisplays(mode: enabled ? .all : .selected) }
                    })) { EmptyView() }
                        .toggleStyle(.prism).labelsHidden().accessibilityLabel(N("All displays"))
                }
                ForEach(screens) { display in
                    displayRow(target: display.target, subtitle: displayDetail(display),
                               symbol: display.isBuiltIn ? "laptopcomputer" : "display", connected: true)
                }
                ForEach(disconnected) { target in
                    displayRow(target: target, subtitle: N("Disconnected · selection remembered"), symbol: "display", connected: false)
                }
            }
            if resolved.isEmpty {
                PrismSettingsNote(Text(N("No selected display is connected. Select a display to show the notch.")))
                    .foregroundStyle(PrismTheme.warning)
            }
            PrismSettingsNote(Text(N("A running timer continues when the notch is hidden. Cancel it in Timer to stop it.")))
            if let error = model.error { Text(error).font(.system(size: 12)).foregroundStyle(PrismTheme.danger) }
        } aside: {
            NotchSettingsPreview(model: model, display: previewDisplay)
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didChangeScreenParametersNotification)) { _ in screens = NotchDisplay.connected() }
    }

    private var orderedIDs: [String] { model.visibleIDs + model.availableIDs.filter { !model.visibleIDs.contains($0) } }
    private var resolved: [NotchDisplay] { model.preferences.displays.resolve(in: screens) }
    /// The display the notch appears on first: the main display when it is selected, otherwise the first selected.
    private var previewDisplay: NotchDisplay? { resolved.first(where: \.isMain) ?? resolved.first ?? screens.first(where: \.isMain) }
    private var disconnected: [NotchDisplayTarget] {
        guard model.preferences.displays.mode == .selected else { return [] }
        return model.preferences.displays.targets.filter { target in !screens.contains { target.matches($0) } }
    }

    private func toolRow(_ id: String) -> some View {
        let pinned = model.visibleIDs.contains(id)
        return HStack(spacing: 11) {
            Image(systemName: model.symbol(for: id))
                .font(.system(size: 13))
                .foregroundStyle(pinned ? PrismTheme.text : PrismTheme.textMuted)
                .frame(width: 26, height: 26)
                .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(pinned ? PrismTheme.surfaceStrong : .clear))
            Text(verbatim: model.title(for: id))
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(pinned ? PrismTheme.text : PrismTheme.textSecondary)
            Spacer(minLength: 8)
            Toggle(isOn: Binding(get: { pinned }, set: { model.setWidget(id, visible: $0) })) { EmptyView() }
                .toggleStyle(.prism).labelsHidden().accessibilityLabel(model.title(for: id))
        }
        .frame(minHeight: 46)
        .padding(.leading, 20)
        .overlay(alignment: .leading) {
            if pinned {
                Image(systemName: "line.3.horizontal")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(PrismTheme.textMuted)
                    .frame(width: 14)
                    .help(N("Drag to reorder"))
            }
        }
        .contentShape(Rectangle())
        .opacity(dragging == id ? 0.4 : 1)
        .modifier(ToolReordering(id: id, enabled: pinned, model: model, dragging: $dragging))
        .accessibilityActions {
            if pinned, model.visibleIDs.first != id {
                Button(N("Move earlier")) { model.moveWidget(id, by: -1) }
            }
            if pinned, model.visibleIDs.last != id {
                Button(N("Move later")) { model.moveWidget(id, by: 1) }
            }
        }
    }

    private func displayDetail(_ display: NotchDisplay) -> String {
        let size = "\(Int(display.frame.width)) × \(Int(display.frame.height))"
        return display.isMain ? size + " · " + N("Main display") : size
    }

    private func displayRow(target: NotchDisplayTarget, subtitle: String, symbol: String, connected: Bool) -> some View {
        let selected = !connected || resolved.contains { target.matches($0) }
        let name = target.name.isEmpty ? N("Disconnected display") : target.name
        return Button { model.setDisplay(target, selected: !selected, connected: screens) } label: {
            HStack(spacing: 11) {
                Image(systemName: symbol).font(.system(size: 15))
                    .foregroundStyle(connected ? PrismTheme.textSecondary : PrismTheme.textMuted)
                    .frame(width: 26)
                VStack(alignment: .leading, spacing: 3) {
                    Text(verbatim: name).font(.system(size: 12, weight: .semibold)).foregroundStyle(PrismTheme.text).lineLimit(1)
                    Text(verbatim: subtitle).font(.system(size: 10.5)).foregroundStyle(PrismTheme.textMuted).lineLimit(1)
                }
                Spacer(minLength: 8)
                Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 15))
                    .foregroundStyle(selected ? PrismTheme.text : PrismTheme.textMuted)
            }
            .frame(minHeight: 50)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(name)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

/// Pinned tools reorder by dragging a row onto another; the notch and its preview follow as rows pass.
private struct ToolReordering: ViewModifier {
    let id: String
    let enabled: Bool
    let model: NotchModel
    @Binding var dragging: String?

    func body(content: Content) -> some View {
        if enabled {
            content
                .onDrag {
                    dragging = id
                    return NSItemProvider(object: id as NSString)
                }
                .onDrop(of: [.text], delegate: ToolDropDelegate(target: id, model: model, dragging: $dragging))
        } else {
            content
        }
    }
}

private struct ToolDropDelegate: DropDelegate {
    let target: String
    let model: NotchModel
    @Binding var dragging: String?

    func dropEntered(info: DropInfo) {
        guard let dragging, dragging != target else { return }
        withAnimation(.easeOut(duration: 0.16)) { model.moveWidget(dragging, to: target) }
    }

    func dropUpdated(info: DropInfo) -> DropProposal? { DropProposal(operation: .move) }

    func performDrop(info: DropInfo) -> Bool {
        dragging = nil
        return true
    }
}
