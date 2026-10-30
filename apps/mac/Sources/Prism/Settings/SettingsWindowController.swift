import AppKit
import Observation
import PrismKit
import SwiftUI

@MainActor
@Observable
final class SettingsModel {
    var panes: [SettingsPane] = []
    var selection: String = GeneralSettingsPane.id
    var query = ""

    /// Panes in sidebar order, narrowed by the search field to titles and keywords that contain the query.
    var sections: [(group: SettingsPane.Group, panes: [SettingsPane])] {
        let needle = query.trimmingCharacters(in: .whitespaces)
        let visible = needle.isEmpty ? panes : panes.filter { pane in
            ([pane.title] + pane.keywords).contains { $0.localizedStandardContains(needle) }
        }
        return SettingsPane.Group.allCases.compactMap { group in
            let panes = visible.filter { $0.group == group }
            return panes.isEmpty ? nil : (group, panes)
        }
    }
}

/// The Tauri settings window: the same glass as the palette, a branded sidebar with search and three groups,
/// and flat pages on the right.
@MainActor
final class SettingsWindowController: NSObject, NSWindowDelegate {
    let model = SettingsModel()
    private var window: NSWindow?
    private var glass: PrismGlassView?
    static let size = NSSize(width: 880, height: 620)

    func install(_ panes: [SettingsPane]) {
        model.panes = panes.sorted { ($0.group.rawValue, $0.order) < ($1.group.rawValue, $1.order) }
    }

    func show(paneID: String? = nil) {
        if let paneID { model.selection = paneID }
        let window = window ?? makeWindow()
        self.window = window
        if !window.isVisible { window.center() }
        NSApp.activate()
        window.makeKeyAndOrderFront(nil)
    }

    func makeWindow() -> NSWindow {
        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: Self.size),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered, defer: false
        )
        window.title = String(localized: "Prism Settings", bundle: .module)
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.isOpaque = false
        window.backgroundColor = .clear
        // Sliders and other drags must not move the window; the sidebar top and page header carry drag areas.
        window.isMovableByWindowBackground = false
        window.isReleasedWhenClosed = false
        window.tabbingMode = .disallowed
        window.minSize = NSSize(width: 760, height: 520)
        window.delegate = self

        let glass = NSView.prismGlassBackground(opacity: PaletteController.backgroundOpacity)
        glass.setBlurRadius(Glass.blur)
        let host = NSHostingView(rootView: SettingsRootView(model: model))
        host.translatesAutoresizingMaskIntoConstraints = false
        glass.contentView.addSubview(host)
        NSLayoutConstraint.activate([
            host.leadingAnchor.constraint(equalTo: glass.contentView.leadingAnchor),
            host.trailingAnchor.constraint(equalTo: glass.contentView.trailingAnchor),
            host.topAnchor.constraint(equalTo: glass.contentView.topAnchor),
            host.bottomAnchor.constraint(equalTo: glass.contentView.bottomAnchor),
        ])
        window.contentView = glass
        self.glass = glass
        NotificationCenter.default.addObserver(forName: UserDefaults.didChangeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.glass?.setOpacity(PaletteController.backgroundOpacity)
                self?.glass?.setBlurRadius(Glass.blur)
            }
        }
        window.setContentSize(Self.size)
        return window
    }
}

struct SettingsRootView: View {
    @Bindable var model: SettingsModel

    var body: some View {
        HStack(spacing: 0) {
            SettingsSidebar(model: model)
                .frame(width: 200)
                .background(alignment: .top) { WindowDragArea().frame(height: 44) }
            ZStack {
                if let pane = model.panes.first(where: { $0.id == model.selection }) {
                    pane.content()
                        .id(pane.id)
                        .transition(.opacity)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(alignment: .top) { WindowDragArea().frame(height: 96) }
            .animation(.easeOut(duration: 0.16), value: model.selection)
        }
        .background(PrismShellOverlay())
        .tint(PrismTheme.accent)
        .frame(minWidth: 760, minHeight: 520)
        .ignoresSafeArea()
    }
}

private struct SettingsSidebar: View {
    @Bindable var model: SettingsModel
    @FocusState private var searchFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                PrismMark().frame(width: 30, height: 30)
                Text(verbatim: "PRISM")
                    .font(.system(size: 15, weight: .semibold))
                    .tracking(2.1)
                    .foregroundStyle(PrismTheme.text)
            }
            .padding(.horizontal, 11)
            .frame(height: 33)

            HStack(spacing: 7) {
                Image(systemName: "magnifyingglass").font(.system(size: 11, weight: .medium))
                    .foregroundStyle(PrismTheme.textMuted)
                TextField(text: $model.query, prompt: Text("Search settings…", bundle: .module)) {
                    Text("Search settings…", bundle: .module)
                }
                .textFieldStyle(.plain)
                .font(.system(size: 11, weight: .medium))
                .focused($searchFocused)
                .onKeyPress(.escape) {
                    guard !model.query.isEmpty else { return .ignored }
                    model.query = ""
                    return .handled
                }
                .onSubmit { if let first = model.sections.first?.panes.first { model.selection = first.id } }
            }
            .padding(.horizontal, 9)
            .frame(height: 33)
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(PrismTheme.field))
            .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(searchFocused ? PrismTheme.lineStrong : PrismTheme.line))
            .padding(EdgeInsets(top: 18, leading: 2, bottom: 15, trailing: 2))

            ScrollView {
                VStack(alignment: .leading, spacing: 3) {
                    let sections = model.sections
                    if sections.isEmpty {
                        Text("No matching settings", bundle: .module)
                            .font(.system(size: 11))
                            .foregroundStyle(PrismTheme.textMuted)
                            .padding(10)
                    }
                    ForEach(Array(sections.enumerated()), id: \.element.group) { index, section in
                        Text(verbatim: Self.title(section.group))
                            .font(.system(size: 10, weight: .semibold))
                            .tracking(0.3)
                            .foregroundStyle(PrismTheme.textMuted)
                            .padding(EdgeInsets(top: index == 0 ? 10 : 20, leading: 11, bottom: 7, trailing: 11))
                        ForEach(section.panes) { pane in
                            SidebarButton(pane: pane, isActive: pane.id == model.selection) {
                                model.selection = pane.id
                            }
                        }
                    }
                }
                .padding(.bottom, 12)
            }
            .scrollIndicators(.never)
        }
        .padding(EdgeInsets(top: 44, leading: 12, bottom: 0, trailing: 12))
        .frame(maxHeight: .infinity, alignment: .top)
        .background(PrismTheme.dynamic(dark: 0x000000, darkAlpha: 0x07, light: 0x000000, lightAlpha: 0x04))
    }

    static func title(_ group: SettingsPane.Group) -> String {
        switch group {
        case .preferences: String(localized: "Preferences", bundle: .module)
        case .tools: String(localized: "Tools", bundle: .module)
        case .privacy: String(localized: "Privacy", bundle: .module)
        }
    }
}

private struct SidebarButton: View {
    let pane: SettingsPane
    let isActive: Bool
    let action: () -> Void
    @ViewState private var isHovered = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 9) {
                Image(systemName: pane.systemImage)
                    .font(.system(size: 13))
                    .foregroundStyle(isActive ? PrismTheme.accent : PrismTheme.textMuted)
                    .frame(width: 16, height: 16)
                Text(verbatim: pane.title)
                    .font(.system(size: 12))
                    .foregroundStyle(isActive ? PrismTheme.text : PrismTheme.textSecondary)
                    .lineLimit(1)
                    .allowsTightening(true)
                    .minimumScaleFactor(0.9)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 10)
            .frame(height: 35)
            .background {
                if isActive {
                    RoundedRectangle(cornerRadius: 7, style: .continuous).fill(PrismTheme.selection)
                } else if isHovered {
                    RoundedRectangle(cornerRadius: 7, style: .continuous).fill(PrismTheme.surface)
                }
            }
            .prismHighlight(active: isActive)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
    }
}
