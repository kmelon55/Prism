import AppKit
import Carbon.HIToolbox
import Observation
import PrismCore
import PrismKit
import SwiftUI

enum ShortcutsSettingsPane {
    static let id = "shortcuts"

    /// `toggles` should be the shell's shared store (the one the palette filters with); the default only keeps
    /// older call sites compiling.
    @MainActor
    static func make(hotKeys: CommandHotKeys, aliases: CommandAliases,
                     toggles: CommandToggles = CommandToggles(paths: AppPaths.current()),
                     items: @escaping @MainActor () async -> [PaletteItem]) -> SettingsPane {
        SettingsPane(id: id, title: String(localized: "Commands", bundle: .module), systemImage: "slider.horizontal.3",
                     group: .tools, order: 10, keywords: keywords) {
            ShortcutsSettingsView(hotKeys: hotKeys, aliases: aliases, toggles: toggles, loadItems: items)
        }
    }

    /// Opens the table filtered to one row, for "Configure Application" in the palette's action panel.
    @MainActor
    static func request(query: String) {
        PendingSearch.shared.query = query
    }

    @MainActor
    @Observable
    final class PendingSearch {
        static let shared = PendingSearch()
        var query: String?
    }

    static var keywords: [String] {
        ["Command", "Alias", "Hotkey", "Search commands", "Assigned"]
            .map { String(localized: String.LocalizationValue($0), bundle: .module) }
    }
}

/// Tauri's Settings → Commands: one table of commands with an alias, a global hotkey and an enable switch.
/// The search box also finds applications, quicklinks and snippets so any row can get a hotkey or alias.
private struct ShortcutsSettingsView: View {
    let hotKeys: CommandHotKeys
    let aliases: CommandAliases
    let toggles: CommandToggles
    let loadItems: @MainActor () async -> [PaletteItem]

    @ViewState private var items: [PaletteItem] = []
    @ViewState private var query = ""
    private let pending = ShortcutsSettingsPane.PendingSearch.shared

    private func takePendingSearch() {
        guard let request = pending.query else { return }
        query = request
        pending.query = nil
    }

    var body: some View {
        PrismSettingsPage(String(localized: "Commands", bundle: .module)) {
            VStack(alignment: .leading, spacing: 10) {
                CommandSearchField(query: $query)
                PrismSettingsNote(Text("A shortcut runs the command from any app. An alias finds it first when typed exactly. Applications appear when you search for them.", bundle: .module))
            }
            let sections = sections
            PrismCommandTable {
                ForEach(Array(sections.enumerated()), id: \.element.title) { index, section in
                    if sections.count > 1 || !query.isEmpty {
                        sectionTitle(section.title, first: index == 0)
                    }
                    ForEach(section.items, id: \.id) { item in
                        row(item)
                    }
                }
                if sections.isEmpty {
                    Text("No commands match this search.", bundle: .module)
                        .font(.system(size: 12))
                        .foregroundStyle(PrismTheme.textMuted)
                        .frame(maxWidth: .infinity, minHeight: 64)
                }
            }
        }
        .task { items = await loadItems() }
        .onAppear(perform: takePendingSearch)
        .onChange(of: pending.query) { takePendingSearch() }
    }

    private func sectionTitle(_ title: String, first: Bool) -> some View {
        Text(verbatim: title)
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(PrismTheme.textSecondary)
            .padding(.leading, 10)
            .padding(.top, first ? 16 : 26)
            .padding(.bottom, 6)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func row(_ item: PaletteItem) -> some View {
        let enabled = toggles.isEnabled(item.id)
        let canDisable = CommandToggles.canDisable(item.id)
        return PrismCommandRow(
            title: item.title,
            detail: detail(for: item),
            alias: Binding(get: { aliases.aliases[item.id] ?? "" }, set: { aliases.setAlias($0, for: item.id) }),
            aliasDisabled: aliases.isUnreadable,
            isEnabled: switchBinding(for: item, canDisable: canDisable),
            switchLocked: !canDisable,
            glyph: { PaletteIconView(icon: item.icon).frame(width: 18, height: 18) },
            hotkey: {
                Group {
                    if Self.doubleTapCommands.contains(item.id) {
                        DoubleTapShortcutRecorder(value: hotKeys.commands[item.id]) { value in
                            if let value, CommandHotKeys.doubleTapValues.contains(value) {
                                hotKeys.setDoubleTap(value, for: item.id)
                            } else {
                                hotKeys.setShortcut(value.flatMap(Shortcut.init(accelerator:)), for: item.id)
                            }
                        }
                    } else {
                        ShortcutRecorder(shortcut: Binding(
                            get: { hotKeys.shortcut(for: item.id) },
                            set: { hotKeys.setShortcut($0, for: item.id) }
                        ))
                    }
                }
                .disabled(!enabled)
                .opacity(enabled ? 1 : 0.5)
            }
        )
    }

    /// Commands Tauri could not disable (Settings, Quit) keep a switch that stays on; library rows, files and
    /// scripts have none.
    private func switchBinding(for item: PaletteItem, canDisable: Bool) -> Binding<Bool>? {
        if canDisable {
            return Binding(get: { toggles.isEnabled(item.id) }, set: { setEnabled($0, item: item) })
        }
        return CommandToggles.requiredCommandIDs.contains(item.id) ? .constant(true) : nil
    }

    /// Like Tauri, switching a command off releases its hotkey first.
    private func setEnabled(_ enabled: Bool, item: PaletteItem) {
        if !enabled, hotKeys.commands[item.id] != nil {
            hotKeys.setShortcut(nil, for: item.id)
        }
        toggles.setEnabled(enabled, for: item.id)
    }

    private func detail(for item: PaletteItem) -> Text? {
        if hotKeys.failures.contains(item.id) {
            return Text("Used by macOS or another app", bundle: .module).foregroundColor(PrismTheme.danger)
        }
        if !toggles.isEnabled(item.id) {
            return Text("Off", bundle: .module)
        }
        if query.isEmpty || item.subtitle.isEmpty { return nil }
        return Text(verbatim: item.subtitle)
    }

    /// Dictation can also start from a modifier double-tap, which the dictation module detects itself.
    static let doubleTapCommands: Set<String> = ["prism:dictation", "prism:dictation-prompt"]

    private var sections: [(title: String, items: [PaletteItem])] {
        let assigned = items.filter { hotKeys.commands[$0.id] != nil || aliases.aliases[$0.id] != nil }
        let visible: [PaletteItem]
        if query.isEmpty {
            let applications = String(localized: "Applications", bundle: .module)
            visible = items.filter { hotKeys.commands[$0.id] == nil && aliases.aliases[$0.id] == nil && $0.section != applications }
        } else {
            visible = CommandSearch.rank(items, query: query, aliases: aliases.searchAliases) { $0.candidate }
        }
        var result: [(String, [PaletteItem])] = []
        if query.isEmpty, !assigned.isEmpty { result.append((String(localized: "Assigned", bundle: .module), assigned)) }
        var order: [String] = []
        var buckets: [String: [PaletteItem]] = [:]
        for item in visible {
            if buckets[item.section] == nil { order.append(item.section) }
            buckets[item.section, default: []].append(item)
        }
        result += order.map { ($0, buckets[$0] ?? []) }
        return result
    }
}

/// The search well above the table, styled like the Tauri settings inputs (33 pt, radius 8, field fill).
private struct CommandSearchField: View {
    @Binding var query: String
    @FocusState private var focused: Bool

    var body: some View {
        HStack(spacing: 7) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(PrismTheme.textMuted)
            TextField(text: $query, prompt: Text("Search commands", bundle: .module)) {
                Text("Search commands", bundle: .module)
            }
            .textFieldStyle(.plain)
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(PrismTheme.text)
            .focused($focused)
            .onKeyPress(.escape) {
                guard !query.isEmpty else { return .ignored }
                query = ""
                return .handled
            }
            if !query.isEmpty {
                Button { query = "" } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 11))
                        .foregroundStyle(PrismTheme.textMuted)
                }
                .buttonStyle(.plain)
                .help(Text("Clear", bundle: .module))
            }
        }
        .padding(.horizontal, 11)
        .frame(height: 33)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(PrismTheme.field))
        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous)
            .strokeBorder(focused ? PrismTheme.lineStrong : PrismTheme.line))
    }
}

/// The hotkey cell for dictation: like `ShortcutRecorder`, but tapping a modifier twice (⌃⌃, ⌥⌥, ⇧⇧, ⌘⌘)
/// records a double-tap, as Tauri's "Key combo / modifier twice…" recorder did.
private struct DoubleTapShortcutRecorder: View {
    /// The raw stored value: an accelerator or one of `CommandHotKeys.doubleTapValues`.
    let value: String?
    let onChange: (String?) -> Void

    @ViewState private var isRecording = false
    @ViewState private var monitor: Any?
    @ViewState private var lastTap: (modifier: String, time: TimeInterval)?
    @ViewState private var pressed: String?

    var body: some View {
        HStack(spacing: 4) {
            Button(action: toggle) {
                Group {
                    if isRecording {
                        Text("Key combo / modifier twice…", bundle: .module)
                            .font(.system(size: 10.5, weight: .semibold))
                            .foregroundStyle(PrismTheme.text)
                            .lineLimit(1)
                            .minimumScaleFactor(0.8)
                    } else if let keys = displayKeys {
                        HStack(spacing: 3) {
                            ForEach(Array(keys.enumerated()), id: \.offset) { _, key in KeyCap(key) }
                        }
                    } else {
                        Text("Record Hotkey", bundle: .module)
                            .font(.system(size: 10.5, weight: .semibold))
                            .foregroundStyle(PrismTheme.textMuted)
                    }
                }
                .padding(.horizontal, 8)
                .frame(minWidth: 96, minHeight: 28)
                .background(RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(isRecording ? PrismTheme.surfaceSelected : .clear))
                .overlay(RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .strokeBorder(isRecording ? PrismTheme.lineStrong : .clear))
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(Text("Press a key combination, or tap a modifier twice.", bundle: .module))
            if value != nil, !isRecording {
                Button { onChange(nil) } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(PrismTheme.textMuted)
                        .frame(width: 20, height: 20)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(Text("Remove Shortcut", bundle: .module))
            }
        }
        .onDisappear(perform: stop)
    }

    private static let modifierSymbols = ["DoubleControl": "⌃", "DoubleOption": "⌥", "DoubleShift": "⇧", "DoubleCommand": "⌘"]

    private var displayKeys: [String]? {
        guard let value else { return nil }
        if let symbol = Self.modifierSymbols[value] { return [symbol, symbol] }
        return Shortcut(accelerator: value)?.displayKeys
    }

    private func toggle() {
        isRecording ? stop() : start()
    }

    private func start() {
        isRecording = true
        lastTap = nil
        pressed = nil
        ShortcutRecording.onRecordingChanged?(true)
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .flagsChanged]) { event in
            event.type == .flagsChanged ? flagsChanged(event) : keyDown(event)
        }
    }

    private func keyDown(_ event: NSEvent) -> NSEvent? {
        lastTap = nil
        pressed = nil
        let code = Int(event.keyCode)
        if code == kVK_Escape {
            stop()
            return nil
        }
        let modifiers = event.modifierFlags.intersection([.command, .option, .control, .shift])
        if (code == kVK_Delete || code == kVK_ForwardDelete) && modifiers.isEmpty {
            onChange(nil)
            stop()
            return nil
        }
        let functionKeys = [kVK_F1, kVK_F2, kVK_F3, kVK_F4, kVK_F5, kVK_F6, kVK_F7, kVK_F8, kVK_F9, kVK_F10, kVK_F11, kVK_F12]
        guard functionKeys.contains(code) || !modifiers.intersection([.command, .option, .control]).isEmpty else {
            NSSound.beep()
            return nil
        }
        onChange(Shortcut(keyCode: UInt32(code), modifiers: modifiers).accelerator)
        stop()
        return nil
    }

    /// A tap is one modifier pressed and released alone; two taps of the same modifier within 0.4 s record it.
    private func flagsChanged(_ event: NSEvent) -> NSEvent? {
        let flags = event.modifierFlags.intersection([.command, .option, .control, .shift])
        let single: String? = switch flags {
        case .control: "DoubleControl"
        case .option: "DoubleOption"
        case .shift: "DoubleShift"
        case .command: "DoubleCommand"
        default: nil
        }
        if let single {
            pressed = single
            return nil
        }
        guard flags.isEmpty, let released = pressed else {
            pressed = nil
            lastTap = nil
            return nil
        }
        pressed = nil
        let now = event.timestamp
        if let lastTap, lastTap.modifier == released, now - lastTap.time < 0.4 {
            onChange(released)
            stop()
        } else {
            lastTap = (released, now)
        }
        return nil
    }

    private func stop() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        if isRecording { ShortcutRecording.onRecordingChanged?(false) }
        isRecording = false
    }
}
