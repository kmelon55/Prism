import AppKit
import ApplicationServices
import PrismKit
import SwiftUI

enum WindowManagementPane {
    static let id = "window-management"

    @MainActor
    static func make(store: WindowOptionsStore, context: any PrismContext) -> SettingsPane {
        SettingsPane(id: id, title: String(localized: "Window Management", bundle: .module), systemImage: "square.dashed", group: .tools, order: 0,
                     keywords: keywords) { [weak context] in
            WindowManagementView(store: store) { context?.openSettings(paneID: PermissionsPane.id) }
        }
    }

    static var keywords: [String] {
        ["Cycle window sizes", "Cycle order", "Window gap", "Screen edge gap", "Almost Maximize size", "Layouts & shortcuts"]
            .map(SystemStrings.localized) + WindowLayout.allCases.map(\.title)
    }
}

@MainActor
@Observable
final class WindowOptionsModel {
    var options = WindowOptions()
    private(set) var loaded = false
    private(set) var error: WindowOptionsError?
    private let store: WindowOptionsStore
    private var pendingSave: Task<Void, Never>?

    init(store: WindowOptionsStore) {
        self.store = store
    }

    func load() {
        do {
            options = try store.load()
            loaded = true
            error = nil
        } catch {
            self.error = error
        }
    }

    /// Saves shortly after the last change so dragging a slider writes once.
    func change(_ update: (inout WindowOptions) -> Void) {
        update(&options)
        pendingSave?.cancel()
        let options = options
        pendingSave = Task { [store] in
            try? await Task.sleep(for: .milliseconds(250))
            guard !Task.isCancelled else { return }
            do throws(WindowOptionsError) { try store.save(options); error = nil } catch { self.error = error }
        }
    }

    func resetDamagedFile() {
        do {
            try store.reset()
            load()
        } catch {
            self.error = error
        }
    }
}

/// The Tauri window section: a live preview, the options card, then every layout with its alias and hotkey.
private struct WindowManagementView: View {
    @ViewState private var model: WindowOptionsModel
    @ViewState private var accessibilityGranted = AXIsProcessTrusted()
    @ViewState private var filter = Filter.all
    @ViewState private var preview = PreviewState()
    let openPermissions: () -> Void

    enum Filter: Hashable { case all, split, position, display }

    init(store: WindowOptionsStore, openPermissions: @escaping () -> Void) {
        _model = ViewState(initialValue: WindowOptionsModel(store: store))
        self.openPermissions = openPermissions
    }

    var body: some View {
        PrismSettingsPage(String(localized: "Window Management", bundle: .module)) {
            VStack(alignment: .leading, spacing: 0) {
                WindowLayoutPreview(options: model.options, state: $preview)
                    .padding(.top, 4)
                    .padding(.bottom, 20)
                options
                if let error = model.error { errorRow(error).padding(.top, 10) }
            }
            VStack(alignment: .leading, spacing: 0) {
                layoutsHeader
                    .padding(.bottom, 12)
                if !accessibilityGranted { permissionNotice.padding(.bottom, 18) }
                layoutsTable
            }
            .padding(.top, -8)
        }
        .onAppear { model.load() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            accessibilityGranted = AXIsProcessTrusted()
        }
        .task {
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(2))
                accessibilityGranted = AXIsProcessTrusted()
            }
        }
    }

    // MARK: Options

    private var options: some View {
        VStack(alignment: .leading, spacing: 0) {
            row(Text("Cycle window sizes", bundle: .module), detail: Text("Repeat Left or Right Half to change size.", bundle: .module)) {
                Toggle(isOn: binding(\.cycle)) { EmptyView() }.toggleStyle(.prism).labelsHidden()
            }
            if model.options.cycle {
                row(Text("Cycle order", bundle: .module)) {
                    PrismSelect(selection: binding(\.reverseCycle), options: [(false, "1/2 → 1/3 → 2/3"), (true, "1/2 → 2/3 → 1/3")])
                }
                .transition(.opacity)
            }
            slider(\.gap, range: WindowOptions.gapRange, unit: "px", title: Text("Window gap", bundle: .module))
            slider(\.edgeGap, range: WindowOptions.gapRange, unit: "px", title: Text("Screen edge gap", bundle: .module))
            slider(\.almostMaximize, range: WindowOptions.almostMaximizeRange, unit: "%", title: Text("Almost Maximize size", bundle: .module))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .prismSettingsCard()
        .animation(.easeOut(duration: 0.2), value: model.options.cycle)
        .disabled(!model.loaded)
    }

    private func row<Control: View>(_ title: Text, detail: Text? = nil, @ViewBuilder control: () -> Control) -> some View {
        PrismSettingsRow(title, detail: detail, control: control)
            .padding(.horizontal, 16)
    }

    private func slider(_ keyPath: WritableKeyPath<WindowOptions, Int>, range: ClosedRange<Int>, unit: String, title: Text) -> some View {
        row(title) {
            PrismSlider(value: Binding(get: { Double(model.options[keyPath: keyPath]) }, set: { value in
                let rounded = Int(value.rounded())
                guard rounded != model.options[keyPath: keyPath] else { return }
                model.change { $0[keyPath: keyPath] = rounded }
                preview.optionChanged(almostMaximize: keyPath == \.almostMaximize)
            }), in: Double(range.lowerBound)...Double(range.upperBound), step: 1) { "\(Int($0))\(unit)" }
        }
    }

    private func binding<Value>(_ keyPath: WritableKeyPath<WindowOptions, Value>) -> Binding<Value> {
        Binding(get: { model.options[keyPath: keyPath] }, set: { value in
            model.change { $0[keyPath: keyPath] = value }
            preview.optionChanged(almostMaximize: false)
        })
    }

    private func errorRow(_ error: WindowOptionsError) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle").foregroundStyle(PrismTheme.warning)
            Text(verbatim: error.message).foregroundStyle(PrismTheme.textSecondary)
            Spacer(minLength: 8)
            if error == .invalidSaved || error == .invalid || error == .unreadable {
                Button { model.resetDamagedFile() } label: { Text("Reset to Defaults", bundle: .module) }
                    .buttonStyle(.prism)
            }
        }
        .font(.system(size: 11))
    }

    // MARK: Layouts

    private var layoutsHeader: some View {
        HStack(spacing: 10) {
            Text("Layouts & shortcuts", bundle: .module)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(PrismTheme.text)
            Text(verbatim: "\(WindowLayout.allCases.count)")
                .font(.system(size: 15))
                .monospacedDigit()
                .foregroundStyle(PrismTheme.textSecondary)
                .padding(.horizontal, 6)
            PrismSelect(selection: $filter, options: [
                (.all, String(localized: "All layouts", bundle: .module)),
                (.split, String(localized: "Split layouts", bundle: .module)),
                (.position, String(localized: "Size & position", bundle: .module)),
                (.display, String(localized: "Displays", bundle: .module)),
            ])
            .help(Text("Filter window commands", bundle: .module))
            Spacer(minLength: 0)
        }
    }

    /// `.settings-inline-permission`: shown above the layouts while Accessibility is missing.
    private var permissionNotice: some View {
        Button(action: openPermissions) {
            HStack(spacing: 12) {
                Image(systemName: "checkmark.shield").font(.system(size: 15)).foregroundStyle(PrismTheme.warning)
                VStack(alignment: .leading, spacing: 3) {
                    Text("Accessibility access required", bundle: .module)
                        .font(.system(size: 12.5, weight: .semibold)).foregroundStyle(PrismTheme.text)
                    Text("Review permission before using window layouts.", bundle: .module)
                        .font(.system(size: 10.5, weight: .medium)).foregroundStyle(PrismTheme.textMuted)
                }
                Spacer(minLength: 8)
                Text("Open Permissions", bundle: .module).font(.system(size: 11, weight: .semibold)).foregroundStyle(PrismTheme.warning)
            }
            .padding(.horizontal, 15)
            .frame(minHeight: 58)
            .background(RoundedRectangle(cornerRadius: 15, style: .continuous).fill(PrismTheme.warning.opacity(0.08)))
            .overlay(RoundedRectangle(cornerRadius: 15, style: .continuous).strokeBorder(PrismTheme.warning.opacity(0.34)))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var layoutsTable: some View {
        PrismCommandTable(showsHeader: false) {
            HStack(spacing: 12) {
                Text("Layout", bundle: .module).padding(.leading, 49).frame(maxWidth: .infinity, alignment: .leading)
                Text("Alias", bundle: .module).frame(width: PrismCommandRowMetrics.aliasWidth, alignment: .leading)
                Text("Hotkey", bundle: .module).frame(width: PrismCommandRowMetrics.trailingWidth, alignment: .leading)
            }
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(PrismTheme.textMuted)
            .frame(height: 34)
            Rectangle().fill(PrismTheme.separator).frame(height: 1)
            ForEach(visibleLayouts, id: \.self) { layout in
                PrismCommandShortcutRow(commandID: layout.commandID, title: layout.title) {
                    Image(nsImage: WindowLayoutIcon.image(for: layout, size: 27))
                }
            }
        }
    }

    private var visibleLayouts: [WindowLayout] {
        WindowLayout.allCases.filter { layout in
            switch filter {
            case .all: true
            case .split: layout.group == .split
            case .position: layout.group == .position
            case .display: layout.group == .display
            }
        }
    }
}

/// What the preview shows: the side and cycle step of the last button press, or the Almost Maximize size
/// right after that slider moved.
private struct PreviewState: Equatable {
    var side = WindowLayout.leftHalf
    var step = 0
    var almostMaximize = false

    mutating func press(_ layout: WindowLayout, cycle: Bool) {
        step = cycle && side == layout && !almostMaximize ? (step + 1) % 3 : 0
        side = layout
        almostMaximize = false
    }

    mutating func optionChanged(almostMaximize: Bool) {
        step = 0
        self.almostMaximize = almostMaximize
    }
}

/// `.window-live-preview`: a miniature desktop with a dashed half grid and a "Prism" tile that moves between the
/// halves and cycles its width as the buttons are pressed repeatedly, like the real command.
private struct WindowLayoutPreview: View {
    let options: WindowOptions
    @Binding var state: PreviewState

    var body: some View {
        HStack(alignment: .center, spacing: 24) {
            desktop
                .frame(maxWidth: .infinity)
            VStack(alignment: .leading, spacing: 12) {
                Text("Try repeating a command", bundle: .module)
                    .font(.system(size: 11))
                    .foregroundStyle(PrismTheme.textSecondary)
                HStack(spacing: 8) {
                    Spacer(minLength: 0)
                    ForEach([WindowLayout.leftHalf, .rightHalf], id: \.self) { layout in
                        Button {
                            withAnimation(.easeInOut(duration: 0.22)) { state.press(layout, cycle: options.cycle) }
                        } label: {
                            HStack(spacing: 7) {
                                Image(systemName: "arrow.counterclockwise").font(.system(size: 11, weight: .medium))
                                Text(verbatim: layout.title)
                            }
                        }
                        .buttonStyle(.prism)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text("Window layout preview", bundle: .module))
    }

    private var desktop: some View {
        GeometryReader { proxy in
            let frame = tileFrame(in: proxy.size)
            ZStack(alignment: .topLeading) {
                // The dashed outline of the work area with its center line.
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .strokeBorder(Self.dash, style: StrokeStyle(lineWidth: 1, dash: [3, 3]))
                    .padding(8)
                Path { path in
                    path.move(to: CGPoint(x: proxy.size.width / 2, y: 8))
                    path.addLine(to: CGPoint(x: proxy.size.width / 2, y: proxy.size.height - 8))
                }
                .stroke(Self.dash, style: StrokeStyle(lineWidth: 1, dash: [3, 3]))
                VStack(alignment: .leading) {
                    Text(verbatim: "Prism").font(.system(size: 9)).opacity(0.7)
                    Spacer(minLength: 0)
                    Text(verbatim: label).font(.system(size: 22, weight: .medium)).tracking(-0.88)
                }
                .foregroundStyle(PrismTheme.text)
                .padding(9)
                .frame(width: frame.width, height: frame.height, alignment: .topLeading)
                .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(PrismTheme.surfaceSelected))
                .overlay(RoundedRectangle(cornerRadius: 7, style: .continuous).strokeBorder(PrismTheme.lineStrong))
                .shadow(color: .black.opacity(0.1), radius: 6, y: 4)
                .offset(x: frame.minX, y: frame.minY)
            }
        }
        .frame(height: 136)
        .prismSettingsCard(cornerRadius: 12)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .animation(.easeInOut(duration: 0.22), value: frame(for: options))
    }

    /// The Tauri tile geometry: a share of the full width minus the scaled gaps, inset 8 pt plus a quarter of
    /// the screen edge gap.
    private func tileFrame(in size: CGSize) -> CGRect {
        if state.almostMaximize {
            let share = CGFloat(options.almostMaximize) / 100
            return CGRect(x: size.width * (1 - share) / 2, y: size.height * (1 - share) / 2,
                          width: size.width * share, height: size.height * share)
        }
        let inset = 8 + CGFloat(options.edgeGap) / 4
        let width = max(30, size.width * fraction - CGFloat(options.edgeGap) / 4 - CGFloat(options.gap) / 8)
        let x = state.side == .leftHalf ? inset : size.width - inset - width
        return CGRect(x: x, y: inset, width: width, height: max(30, size.height - inset * 2))
    }

    /// Animation key: changes whenever the tile moves.
    private func frame(for options: WindowOptions) -> [Double] {
        [Double(state.step), state.side == .leftHalf ? 0 : 1, state.almostMaximize ? 1 : 0,
         Double(options.gap), Double(options.edgeGap), Double(options.almostMaximize)]
    }

    private var fraction: CGFloat {
        let thirds: [CGFloat] = options.reverseCycle ? [3, 4, 2] : [3, 2, 4]
        return thirds[state.step] / 6
    }

    private var label: String {
        if state.almostMaximize { return "\(options.almostMaximize)%" }
        let names = options.reverseCycle ? ["1/2", "2/3", "1/3"] : ["1/2", "1/3", "2/3"]
        return names[state.step]
    }

    static let dash = PrismTheme.dynamic(dark: 0xA0A0A0, darkAlpha: 0x30, light: 0x707070, lightAlpha: 0x40)
}
