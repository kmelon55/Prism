import AppKit
import PrismKit
import SwiftUI
import UniformTypeIdentifiers

/// Settings → Keyboard: the master switch, tap-and-hold keys, remapped shortcuts and apps left alone.
struct KeyboardSettingsView: View {
    let model: KeyboardModel
    let openPermissions: () -> Void

    var body: some View {
        PrismSettingsPage(String(localized: "Keyboard", bundle: .module.prismLocalized)) {
            PrismSettingsGroup {
                PrismSettingsRow(Text("Keyboard remapping", bundle: .module.prismLocalized),
                                 detail: Text("Change what keys do in every app. Turning this off restores every key at once.", bundle: .module.prismLocalized)) {
                    Toggle(isOn: binding(\.enabled)) { EmptyView() }.toggleStyle(.prism).labelsHidden()
                }
                if let error = model.lastError {
                    PrismSettingsNote(Text(verbatim: error).foregroundColor(PrismTheme.danger))
                }
            }
            if model.config.enabled && !model.accessibilityGranted { permissionNotice }
            dualRoles
            remaps
            excludedApps
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            model.refreshPermission()
        }
    }

    static var keywords: [String] {
        ["Keyboard remapping", "Tap and hold", "Remapped shortcuts", "Hold delay", "Apps without tap and hold", "Hyper key", "Caps Lock", "Space"]
            .map { String(localized: String.LocalizationValue($0), bundle: .module.prismLocalized) }
    }

    // MARK: Tap and hold

    private var dualRoles: some View {
        PrismSettingsGroup(Text("Tap and hold", bundle: .module.prismLocalized)) {
            Menu {
                Button { addDualRole(.spaceCommand) } label: { Text("Space: tap for Space, hold for ⌘", bundle: .module.prismLocalized) }
                Button { addDualRole(.capsLockHyper) } label: { Text("Caps Lock: tap for Escape, hold for Hyper (⌃⌥⇧⌘)", bundle: .module.prismLocalized) }
                Divider()
                Button { addDualRole(DualRoleRule(trigger: .return, tap: .same, hold: .control)) } label: { Text("Custom Key", bundle: .module.prismLocalized) }
            } label: {
                Label { Text("Add Key", bundle: .module.prismLocalized) } icon: { Image(systemName: "plus") }
            }
            .menuStyle(.button)
            .buttonStyle(.prism)
            .menuIndicator(.hidden)
            .fixedSize()
        } content: {
            if model.config.dualRoles.isEmpty {
                PrismSettingsRow(Text("No keys yet", bundle: .module.prismLocalized),
                                 detail: Text("A tap-and-hold key types normally when tapped and acts as modifier keys while held, such as Space as ⌘.", bundle: .module.prismLocalized))
            }
            ForEach(model.config.dualRoles) { rule in
                DualRoleRow(rule: rule, change: { next in
                    model.change { config in
                        if let index = config.dualRoles.firstIndex(where: { $0.id == rule.id }) { config.dualRoles[index] = next }
                    }
                }, remove: {
                    model.change { $0.dualRoles.removeAll { $0.id == rule.id } }
                })
            }
            PrismSettingsRow(Text("Hold delay", bundle: .module.prismLocalized),
                             detail: Text("A key pressed this long after a tap-and-hold key always counts as a shortcut. Shorter feels faster; longer forgives fast typing.", bundle: .module.prismLocalized)) {
                PrismSlider(value: Binding(get: { Double(model.config.holdThreshold) }, set: { value in
                    let rounded = Int((value / 10).rounded() * 10)
                    model.change { $0.holdThreshold = rounded }
                }), in: Double(KeyboardConfig.holdThresholdRange.lowerBound)...Double(KeyboardConfig.holdThresholdRange.upperBound),
                step: 10) { "\(Int($0)) ms" }
            }
        }
    }

    private func addDualRole(_ rule: DualRoleRule) {
        model.change { config in
            var rule = rule
            // A trigger already in use gets the next free one.
            let used = Set(config.dualRoles.map(\.trigger))
            if used.contains(rule.trigger), let free = TriggerKey.allCases.first(where: { !used.contains($0) }) { rule.trigger = free }
            if !rule.trigger.canTypeItself && rule.tap == .same { rule.tap = .escape }
            config.dualRoles.append(rule)
            config.enabled = true
        }
    }

    // MARK: Remapped shortcuts

    private var remaps: some View {
        PrismSettingsGroup(Text("Remapped shortcuts", bundle: .module.prismLocalized)) {
            Button {
                model.change { $0.remaps.append(ShortcutRemap()) }
            } label: {
                Label { Text("Add Shortcut", bundle: .module.prismLocalized) } icon: { Image(systemName: "plus") }
            }
            .buttonStyle(.prism)
        } content: {
            if model.config.remaps.isEmpty {
                PrismSettingsRow(Text("No shortcuts yet", bundle: .module.prismLocalized),
                                 detail: Text("Replace one shortcut with another, everywhere or only in one app.", bundle: .module.prismLocalized))
            }
            ForEach(model.config.remaps) { remap in
                RemapRow(remap: remap, change: { next in
                    model.change { config in
                        if let index = config.remaps.firstIndex(where: { $0.id == remap.id }) { config.remaps[index] = next }
                    }
                }, remove: {
                    model.change { $0.remaps.removeAll { $0.id == remap.id } }
                }, onRecordingChanged: model.setRecording)
            }
        }
    }

    // MARK: Excluded apps

    private var excludedApps: some View {
        PrismSettingsGroup(Text("Apps without tap and hold", bundle: .module.prismLocalized)) {
            Button {
                guard let app = AppPicker.choose(), !model.config.excludedApps.contains(app) else { return }
                model.change { $0.excludedApps.append(app) }
            } label: {
                Label { Text("Add App", bundle: .module.prismLocalized) } icon: { Image(systemName: "plus") }
            }
            .buttonStyle(.prism)
        } content: {
            if model.config.excludedApps.isEmpty {
                PrismSettingsRow(Text("No apps", bundle: .module.prismLocalized),
                                 detail: Text("Tap-and-hold keys type normally in these apps, such as games. Remapped shortcuts still apply.", bundle: .module.prismLocalized))
            }
            ForEach(model.config.excludedApps, id: \.bundleID) { app in
                PrismSettingsRow(Text(verbatim: app.name), detail: Text(verbatim: app.bundleID)) {
                    RemoveButton { model.change { $0.excludedApps.removeAll { $0 == app } } }
                }
            }
        }
    }

    // MARK: Permission

    private var permissionNotice: some View {
        Button(action: openPermissions) {
            HStack(spacing: 12) {
                Image(systemName: "checkmark.shield").font(.system(size: 15)).foregroundStyle(PrismTheme.warning)
                VStack(alignment: .leading, spacing: 3) {
                    Text("Accessibility access required", bundle: .module.prismLocalized)
                        .font(.system(size: 12.5, weight: .semibold)).foregroundStyle(PrismTheme.text)
                    Text("Allow Prism in Accessibility to change what keys do.", bundle: .module.prismLocalized)
                        .font(.system(size: 10.5, weight: .medium)).foregroundStyle(PrismTheme.textMuted)
                }
                Spacer(minLength: 8)
                Text("Open Permissions", bundle: .module.prismLocalized).font(.system(size: 11, weight: .semibold)).foregroundStyle(PrismTheme.warning)
            }
            .padding(.horizontal, 15)
            .frame(minHeight: 58)
            .background(RoundedRectangle(cornerRadius: 15, style: .continuous).fill(PrismTheme.warning.opacity(0.08)))
            .overlay(RoundedRectangle(cornerRadius: 15, style: .continuous).strokeBorder(PrismTheme.warning.opacity(0.34)))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func binding<Value>(_ keyPath: WritableKeyPath<KeyboardConfig, Value>) -> Binding<Value> {
        Binding(get: { model.config[keyPath: keyPath] }, set: { value in model.change { $0[keyPath: keyPath] = value } })
    }
}

/// One tap-and-hold key: the key, what a tap types, what holding it presses, its switch and a remove button.
private struct DualRoleRow: View {
    let rule: DualRoleRule
    let change: (DualRoleRule) -> Void
    let remove: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            PrismSelect(selection: binding(\.trigger), options: TriggerKey.allCases.map { ($0, $0.title) }, minWidth: 96)
            label(Text("Tap", bundle: .module.prismLocalized))
            PrismSelect(selection: binding(\.tap), options: tapOptions, minWidth: 96)
            label(Text("Hold", bundle: .module.prismLocalized))
            PrismSelect(selection: binding(\.hold), options: HoldModifiers.allCases.map { ($0, $0.title) }, minWidth: 124)
            Spacer(minLength: 8)
            Toggle(isOn: binding(\.isEnabled)) { EmptyView() }.toggleStyle(.prism).labelsHidden()
            RemoveButton(action: remove)
        }
        .padding(.vertical, 11)
        .frame(minHeight: 54)
    }

    private var tapOptions: [(value: TapOutput, title: String)] {
        TapOutput.allCases.filter { $0 != .same || rule.trigger.canTypeItself }.map { ($0, $0.title(trigger: rule.trigger)) }
    }

    private func label(_ text: Text) -> some View {
        text.font(.system(size: 11)).foregroundStyle(PrismTheme.textMuted)
    }

    private func binding<Value>(_ keyPath: WritableKeyPath<DualRoleRule, Value>) -> Binding<Value> {
        Binding(get: { rule[keyPath: keyPath] }, set: { value in
            var next = rule
            next[keyPath: keyPath] = value
            if !next.trigger.canTypeItself && next.tap == .same { next.tap = .escape }
            change(next)
        })
    }
}

/// One remapped shortcut: from, to, where it applies, its switch and a remove button.
private struct RemapRow: View {
    let remap: ShortcutRemap
    let change: (ShortcutRemap) -> Void
    let remove: () -> Void
    let onRecordingChanged: (Bool) -> Void

    enum Scope: Hashable {
        case everywhere, app(AppReference), choose
    }

    var body: some View {
        HStack(spacing: 10) {
            KeyComboRecorder(combo: binding(\.from), onRecordingChanged: onRecordingChanged)
            Image(systemName: "arrow.right").font(.system(size: 10, weight: .semibold)).foregroundStyle(PrismTheme.textMuted)
            KeyComboRecorder(combo: binding(\.to), onRecordingChanged: onRecordingChanged)
            Spacer(minLength: 8)
            PrismSelect(selection: scope, options: scopeOptions, minWidth: 96)
            Toggle(isOn: binding(\.isEnabled)) { EmptyView() }.toggleStyle(.prism).labelsHidden()
            RemoveButton(action: remove)
        }
        .padding(.vertical, 11)
        .frame(minHeight: 54)
    }

    private var scopeOptions: [(value: Scope, title: String)] {
        var options: [(value: Scope, title: String)] = [(.everywhere, String(localized: "All Apps", bundle: .module.prismLocalized))]
        if let app = remap.app { options.append((.app(app), app.name)) }
        options.append((.choose, String(localized: "Choose App…", bundle: .module.prismLocalized)))
        return options
    }

    private var scope: Binding<Scope> {
        Binding(get: { remap.app.map(Scope.app) ?? .everywhere }, set: { value in
            var next = remap
            switch value {
            case .everywhere: next.app = nil
            case .app(let app): next.app = app
            case .choose:
                guard let app = AppPicker.choose() else { return }
                next.app = app
            }
            change(next)
        })
    }

    private func binding<Value>(_ keyPath: WritableKeyPath<ShortcutRemap, Value>) -> Binding<Value> {
        Binding(get: { remap[keyPath: keyPath] }, set: { value in
            var next = remap
            next[keyPath: keyPath] = value
            change(next)
        })
    }
}

private struct RemoveButton: View {
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: "minus.circle")
                .font(.system(size: 13))
                .foregroundStyle(PrismTheme.textMuted)
                .frame(width: 24, height: 24)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(Text("Remove", bundle: .module.prismLocalized))
    }
}

@MainActor
enum AppPicker {
    static func choose() -> AppReference? {
        let panel = NSOpenPanel()
        panel.directoryURL = URL(filePath: "/Applications", directoryHint: .isDirectory)
        panel.allowedContentTypes = [.application]
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.prompt = String(localized: "Choose", bundle: .module.prismLocalized)
        guard panel.runModal() == .OK, let url = panel.url, let bundleID = Bundle(url: url)?.bundleIdentifier else { return nil }
        let name = FileManager.default.displayName(atPath: url.path).replacingOccurrences(of: ".app", with: "")
        return AppReference(bundleID: bundleID, name: name)
    }
}

extension TriggerKey {
    var title: String {
        switch self {
        case .space: String(localized: "Space", bundle: .module.prismLocalized)
        case .capsLock: "Caps Lock"
        case .return: "Return ↩"
        case .tab: "Tab ⇥"
        case .escape: "Escape ⎋"
        case .semicolon: ";"
        case .quote: "'"
        }
    }
}

extension TapOutput {
    func title(trigger: TriggerKey) -> String {
        switch self {
        case .same: trigger.title
        case .escape: "Escape ⎋"
        case .return: "Return ↩"
        case .tab: "Tab ⇥"
        case .space: String(localized: "Space", bundle: .module.prismLocalized)
        case .delete: "Delete ⌫"
        case .nothing: String(localized: "Nothing", bundle: .module.prismLocalized)
        }
    }
}

extension HoldModifiers {
    var title: String {
        switch self {
        case .command: "⌘"
        case .control: "⌃"
        case .option: "⌥"
        case .shift: "⇧"
        case .hyper: "Hyper ⌃⌥⇧⌘"
        case .meh: "Meh ⌃⌥⇧"
        }
    }
}
