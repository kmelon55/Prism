import Foundation
import PrismKit

/// A library record the import would create. Same JSON fields as the Tauri `LibraryEntry`.
struct ImportEntry: Codable, Equatable, Sendable {
    var id: String
    var kind: String
    var title: String
    var value: String
    var keyword: String?

    var backupEntry: BackupEntry { BackupEntry(id: id, kind: kind, title: title, value: value, keyword: keyword) }
}

/// One review row, with the same JSON shape as `ImportItem` in `raycastPlan.ts` so recovery records written by
/// either app can be read by the other. Hotkey values use the Tauri form (`Control+Alt+Left`).
struct ImportItem: Codable, Equatable, Identifiable, Sendable {
    enum Category: String, Codable, CaseIterable, Sendable { case hotkeys, aliases, snippets, quicklinks }

    var id: String
    var category: Category
    var title: String
    var value: String
    var commandId: String?
    var before: String?
    var entry: ImportEntry?
    var reason: String?
    var conflict: Bool?

    var isReady: Bool { reason == nil && conflict != true }
    var isConflict: Bool { reason == nil && conflict == true }
}

struct RaycastImportContext {
    struct Application: Equatable, Sendable {
        var path: String
        var name: String
    }

    var apps: [Application] = []
    var entries: [ImportEntry] = []
    var aliases: [String: String] = [:]
    /// Accelerators by command ID, plus the launcher under `launcher`.
    var hotkeys: [String: String] = [:]
    var disabled: Set<String> = []
    /// Localized titles of every command the app has, by ID. When empty, every mapped built-in is accepted.
    var commandTitles: [String: String] = [:]
}

/// Builds the import review, ported from `raycastPlan.ts`.
enum RaycastPlan {
    static let maxItems = 3000
    static let tooMany = "Too many import items."
    static let unsupportedData = "Unsupported Raycast data."
    static let launcherID = "launcher"

    struct Failure: Error, Equatable { let message: String }

    // MARK: Hotkeys

    /// macOS virtual key codes to the names the Tauri plan writes, independent of keyboard layout.
    static let keys: [Int: String] = {
        var keys: [Int: String] = [:]
        let ordered = ["A", "S", "D", "F", "H", "G", "Z", "X", "C", "V", "", "B", "Q", "W", "E", "R", "Y", "T", "1", "2", "3", "4", "6", "5",
                       "Equal", "9", "7", "Minus", "8", "0", "BracketRight", "O", "U", "BracketLeft", "I", "P", "Enter", "L", "J", "Quote",
                       "K", "Semicolon", "Backslash", "Comma", "Slash", "N", "M", "Period", "Tab", "Space", "Backquote", "Backspace"]
        for (code, key) in ordered.enumerated() where !key.isEmpty { keys[code] = key }
        for (code, key) in [(53, "Escape"), (123, "Left"), (124, "Right"), (125, "Down"), (126, "Up"), (115, "Home"), (119, "End"),
                            (116, "PageUp"), (121, "PageDown"), (117, "Delete")] { keys[code] = key }
        for (index, code) in [122, 120, 99, 118, 96, 97, 98, 100, 101, 109, 103, 111].enumerated() { keys[code] = "F\(index + 1)" }
        return keys
    }()

    private static let modifierNames: [String: String] = [
        "command": "Super", "cmd": "Super", "meta": "Super", "super": "Super", "control": "Control", "ctrl": "Control",
        "alt": "Alt", "option": "Alt", "shift": "Shift",
    ]
    private static let modifierOrder = ["Control", "Alt", "Shift", "Super"]

    /// Raycast's `control-option-123` strings and Raycast X `SingleStep` objects. Multi-step or unknown → nil.
    static func hotkey(_ value: Any?) -> String? {
        var code: Int?
        var modifiers: [Any?]
        if let text = value as? String {
            var parts = text.components(separatedBy: "-")
            let last = parts.removeLast()
            code = Int(last)
            modifiers = parts
        } else {
            let kind = record(record(value)["kind"]), shortcut = record(kind["shortcut"]), key = record(shortcut["key"])
            guard kind["type"] as? String == "SingleStep", key["type"] as? String == "LayoutIndependent" else { return nil }
            code = (key["code"] as? NSNumber).flatMap { JSONValue.isBool($0) ? nil : $0.doubleValue == $0.doubleValue.rounded() ? $0.intValue : nil }
            modifiers = list(shortcut["modifiers"]).map { record($0)["modifier"] }
        }
        guard let code, let key = keys[code], !modifiers.isEmpty else { return nil }
        var flags = Set<String>()
        for modifier in modifiers {
            let name = (modifier as? String ?? "").lowercased()
            if name == "hyper" { flags.formUnion(modifierOrder); continue }
            guard let flag = modifierNames[name] else { return nil }
            flags.insert(flag)
        }
        return (modifierOrder.filter(flags.contains) + [key]).joined(separator: "+")
    }

    /// Parses a hotkey written by this plan, the Tauri app or the native shell into a `Shortcut`.
    static func shortcut(_ value: String) -> Shortcut? {
        let arrows = ["left": "ArrowLeft", "right": "ArrowRight", "up": "ArrowUp", "down": "ArrowDown"]
        let parts = value.split(separator: "+").map { part in arrows[part.lowercased()] ?? String(part) }
        return Shortcut(accelerator: parts.joined(separator: "+"))
    }

    /// Whether two hotkeys are the same keys, in any of the accepted spellings.
    static func sameHotkey(_ lhs: String, _ rhs: String) -> Bool {
        if let left = shortcut(lhs), let right = shortcut(rhs) { return left == right }
        return canonicalHotkey(lhs) == canonicalHotkey(rhs)
    }

    static func canonicalHotkey(_ value: String) -> String {
        var parts = value.components(separatedBy: "+")
        let key = parts.popLast() ?? ""
        let flags = Set(parts.map { modifierNames[$0.lowercased()] ?? $0 })
        return (modifierOrder.filter(flags.contains) + [key.lowercased()]).joined(separator: "+")
    }

    // MARK: Commands

    /// The 37 window commands, by the name Raycast uses with dashes and underscores removed.
    static let windowCommands: [String: String] = {
        let layouts = ["left-half", "right-half", "top-half", "bottom-half", "top-left-quarter", "top-right-quarter", "bottom-left-quarter",
                       "bottom-right-quarter", "top-left-sixth", "top-center-sixth", "top-right-sixth", "bottom-left-sixth", "bottom-center-sixth",
                       "bottom-right-sixth", "first-third", "center-third", "last-third", "left-two-thirds", "center-two-thirds",
                       "right-two-thirds", "maximize", "almost-maximize", "center", "maximize-width", "maximize-height", "reasonable-size",
                       "first-fourth", "second-fourth", "third-fourth", "last-fourth", "move-left", "move-right", "move-up", "move-down",
                       "next-display", "previous-display", "restore-previous-layout"]
        var map = Dictionary(uniqueKeysWithValues: layouts.map { ($0.replacingOccurrences(of: "-", with: ""), "window:\($0)") })
        map["firsttwothirds"] = "window:left-two-thirds"
        map["lasttwothirds"] = "window:right-two-thirds"
        map["restore"] = "window:restore-previous-layout"
        map["movenextdisplay"] = "window:next-display"
        map["movepreviousdisplay"] = "window:previous-display"
        return map
    }()

    static let builtins: [String: String] = [
        "clipboardHistory": "clipboard:open-history", "searchEmoji": "prism:emoji", "fileSearch": "prism:files", "searchFiles": "prism:files",
        "searchSnippets": "prism:snippets", "searchQuicklinks": "prism:links", "lockScreen": "system:lock-screen",
        "sleep": "system:sleep", "sleepDisplays": "system:sleep-displays", "restart": "system:restart", "shutDown": "system:shutdown",
        "shutdown": "system:shutdown", "logOut": "system:log-out", "logout": "system:log-out",
        "openPreferences": "prism:preferences", "showPreferences": "prism:preferences", "aiChat": "prism:ai-chat",
    ]

    /// Package and command resolve together, so an extension command that shares a built-in's name never maps
    /// to a system action, and force/immediate variants stay unsupported.
    static let packageBuiltins: [String: [String: String]] = {
        let system = Dictionary(uniqueKeysWithValues: ["lockScreen", "sleep", "sleepDisplays", "restart", "shutDown", "shutdown", "logOut", "logout"]
            .map { ($0, builtins[$0]!) })
        return [
            "system": system, "systemActions": system,
            "clipboardHistory": ["clipboardHistory": "clipboard:open-history"],
            "emoji": ["searchEmoji": "prism:emoji"],
            "fileSearch": ["fileSearch": "prism:files", "searchFiles": "prism:files"],
            "snippets": ["searchSnippets": "prism:snippets"],
            "quicklinks": ["searchQuicklinks": "prism:links"],
            "raycastPreferences": ["openPreferences": "prism:preferences", "showPreferences": "prism:preferences"],
            "open-ai": ["aiChat": "prism:ai-chat"],
        ]
    }()

    private static let applicationPrefix = "c:r:applications::*::application::=::"

    /// The palette ID of an installed app (`app:<path>`), a built-in command ID, or nil.
    static func resolveCommand(key: String, path: String, apps: [RaycastImportContext.Application]) -> String? {
        let appPath = !path.isEmpty ? path : key.hasPrefix(applicationPrefix) ? (key.components(separatedBy: "::=::").dropFirst().first ?? "") : ""
        if !appPath.isEmpty {
            let wanted = appPath.precomposedStringWithCanonicalMapping
            return apps.first { $0.path.precomposedStringWithCanonicalMapping == wanted }.map { "app:\($0.path)" }
        }
        if key.hasPrefix("builtin_command_") {
            let name = String(key.dropFirst("builtin_command_".count))
            if let id = builtins[name] { return id }
            let windowName = name.replacing(/^(?i:windowManagement)[_-]?/, with: "").replacing(/[-_]/, with: "").lowercased()
            return windowCommands[windowName]
        }
        guard let match = key.wholeMatch(of: /c:r:([^:]+)::(?:\*|-)::([^:]+)/) else { return nil }
        let package = String(match.1), name = String(match.2)
        if package == "windowManagement" || package == "window-management" {
            return windowCommands[name.replacing(/[-_]/, with: "").lowercased()]
        }
        return packageBuiltins[package]?[name]
    }

    /// App paths referenced by the export, so the caller can make sure they are in `apps`.
    static func applicationPaths(_ data: Any) throws -> [String] {
        let root = record(data)
        let commands = list(record(root["builtin_package_rootSearch"])["rootSearch"]) + list(record(root["settings"])["commands"])
        if commands.count > maxItems { throw Failure(message: tooMany) }
        var seen = Set<String>(), paths: [String] = []
        for raw in commands {
            let item = record(raw), id = text(item["id"])
            let path = !text(item["path"]).isEmpty ? text(item["path"])
                : id.hasPrefix(applicationPrefix) ? (id.components(separatedBy: "::=::").dropFirst().first ?? "") : ""
            if path.hasSuffix(".app"), path.utf16.count <= 4096, seen.insert(path).inserted { paths.append(path) }
        }
        return paths
    }

    // MARK: Plan

    static func build(_ data: Any, context: RaycastImportContext, makeID: () -> String = { UUID().uuidString.lowercased() }) throws -> [ImportItem] {
        let root = record(data)
        let isArray = data is [Any]
        let classic = root.keys.contains { $0.hasPrefix("builtin_package_") }
        let modern = ["snippets", "quicklinks", "settings"].contains { root[$0] != nil }
        guard isArray || classic || modern else { throw Failure(message: unsupportedData) }
        var rows: [ImportItem] = []
        func add(_ item: ImportItem) throws {
            guard rows.count < maxItems else { throw Failure(message: tooMany) }
            var item = item
            item.id = String(rows.count)
            rows.append(item)
        }

        let array = data as? [Any] ?? []
        let snippetSource = isArray ? array.filter { record($0)["text"] != nil } : list(record(root[classic ? "builtin_package_snippets" : "snippets"])["snippets"])
        let linkSource = isArray ? array.filter { record($0)["text"] == nil } : list(record(root[classic ? "builtin_package_quicklinks" : "quicklinks"])["quicklinks"])
        if snippetSource.count + linkSource.count > maxItems { throw Failure(message: tooMany) }
        for (category, source) in [(ImportItem.Category.snippets, snippetSource), (.quicklinks, linkSource)] {
            for raw in source {
                let item = record(raw)
                let name = !text(item["name"]).isEmpty ? text(item["name"]) : text(item["title"])
                let title = name.isEmpty ? "Untitled" : name
                let original = category == .snippets ? text(item["text"]) : (!text(item["url"]).isEmpty ? text(item["url"]) : text(item["link"]))
                let value = category == .quicklinks ? original.replacing(/\{(?:Query|query|argument)\}/, with: "{query}") : original
                let keyword = !text(item["keyword"]).isEmpty ? text(item["keyword"]) : text(item["alias"])
                var reason: String?
                if name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !safeName(title) || title.utf8.count > 300
                    || value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || value.utf8.count > 128 * 1024 || value.contains("\0") {
                    reason = "Invalid or oversized item"
                }
                let allowed = category == .snippets ? ["{date}", "{time}", "{clipboard}"] : ["{query}"]
                if value.matches(of: /\{[^{}]+\}/).contains(where: { !allowed.contains(String($0.output)) }) { reason = "Unsupported placeholder" }
                if category == .quicklinks, (try? LibraryRules.validateLinkTemplate(value)) == nil { reason = "Unsupported link" }
                // Prism expansion keywords are explicit; keep the content without inventing a new trigger.
                let validKeyword = keyword.wholeMatch(of: /[:;!\/][a-zA-Z0-9_\-;!\/:]{1,47}/) != nil
                let entry = ImportEntry(id: makeID(), kind: category == .snippets ? "snippet" : "link", title: title, value: value,
                                        keyword: category == .snippets && validKeyword ? keyword : nil)
                let pending = rows.compactMap { $0.entry != nil && $0.reason == nil && $0.conflict != true ? $0.entry : nil }
                let duplicate = (context.entries + pending).contains { existing in
                    existing.kind == entry.kind && (existing.value == value || existing.title == title || (entry.keyword != nil && existing.keyword == entry.keyword))
                }
                try add(ImportItem(id: "", category: category, title: title, value: value, entry: entry, reason: reason, conflict: duplicate))
                if category == .snippets, !keyword.isEmpty, !validKeyword {
                    try add(ImportItem(id: "", category: category, title: "\(title) · \(keyword)", value: keyword,
                                       reason: "Expansion keyword needs a prefix (: ; ! /)"))
                }
            }
        }

        var commands = classic ? list(record(root["builtin_package_rootSearch"])["rootSearch"]) : list(record(root["settings"])["commands"])
        if commands.count > maxItems { throw Failure(message: tooMany) }
        if let global = record(record(root["builtin_package_raycastPreferences"])["preferencesGeneral"])["raycastGlobalHotkey"], !(global is NSNull) {
            commands.insert(["key": "prism-launcher", "hotkey": global], at: 0)
        }
        for raw in commands {
            let item = record(raw)
            let key = !text(item["key"]).isEmpty ? text(item["key"]) : text(item["id"])
            var commandId = key == "prism-launcher" ? launcherID : resolveCommand(key: key, path: text(item["path"]), apps: context.apps)
            if let id = commandId, id != launcherID, !id.hasPrefix("app:"), !context.commandTitles.isEmpty, context.commandTitles[id] == nil {
                commandId = nil
            }
            let appName = commandId.flatMap { id in context.apps.first { "app:\($0.path)" == id }?.name }
            let fallback = [text(item["name"]), text(item["path"]).components(separatedBy: "/").last ?? "", key].first { !$0.isEmpty } ?? key
            let title = commandId == launcherID ? L10n.tr("Open or hide Prism")
                : commandId.flatMap { context.commandTitles[$0] ?? appName ?? defaultTitle(for: $0) } ?? fallback
            let hotkeyRaw = item["hotkey"].flatMap { $0 is NSNull ? nil : $0 } ?? item["macosHotkey"]
            let alias = !text(item["alias"]).isEmpty ? text(item["alias"]) : text(item["searchTerms"])
            for category in [ImportItem.Category.hotkeys, .aliases] {
                if category == .hotkeys ? (hotkeyRaw == nil || hotkeyRaw is NSNull || isFalsy(hotkeyRaw)) : alias.isEmpty { continue }
                let value = category == .hotkeys ? hotkey(hotkeyRaw) ?? "" : alias.trimmingCharacters(in: .whitespacesAndNewlines)
                var reason: String?
                if let commandId {
                    if context.disabled.contains(commandId) { reason = "Command is disabled in Prism" }
                } else {
                    reason = "No matching Prism command or installed app"
                }
                if value.isEmpty || (category == .aliases && (!safeName(value) || value.utf16.count > 80)) {
                    reason = category == .hotkeys ? "Unsupported shortcut" : "Unsupported alias"
                }
                let existing = category == .hotkeys ? context.hotkeys : context.aliases
                let isHotkey = category == .hotkeys
                let same = { (lhs: String, rhs: String) -> Bool in
                    isHotkey ? sameHotkey(lhs, rhs) : SafePreferencesMerge.aliasKey(lhs) == SafePreferencesMerge.aliasKey(rhs)
                }
                var conflict = false
                if let commandId {
                    let taken = existing.values.contains { same($0, value) }
                    let pending = rows.contains { row in
                        row.category == category && row.isReady && (row.commandId == commandId || same(row.value, value))
                    }
                    conflict = existing[commandId] != nil || taken || pending
                }
                try add(ImportItem(id: "", category: category, title: title, value: value, commandId: commandId,
                                   before: commandId.flatMap { existing[$0] }, reason: reason, conflict: conflict))
            }
        }
        for key in root.keys.sorted()
        where key.contains(/(?i)windowManagement|extensions|aiChats|clipboardHistory|notes|mcp|scriptCommands|navigation|wrapped|emoji/)
            && !key.contains("rootSearch") {
            try add(ImportItem(id: "", category: .hotkeys, title: key, value: "", reason: "This category is not supported yet"))
        }
        return rows
    }

    /// English titles for built-ins when the app's command list is not available, such as in tests.
    static func defaultTitle(for id: String) -> String? {
        let builtins = [
            "clipboard:open-history": "Clipboard History", "prism:emoji": "Emoji", "prism:files": "Search Files",
            "prism:snippets": "Snippets", "prism:links": "Quicklinks", "prism:preferences": "Settings", "prism:ai-chat": "AI Chat",
            "system:lock-screen": "Lock Screen", "system:sleep": "Sleep", "system:sleep-displays": "Sleep Displays",
            "system:restart": "Restart", "system:shutdown": "Shut Down", "system:log-out": "Log Out",
        ]
        if let title = builtins[id] { return L10n.tr(title) }
        guard id.hasPrefix("window:") else { return nil }
        return id.dropFirst("window:".count).split(separator: "-").map { $0.prefix(1).uppercased() + $0.dropFirst() }.joined(separator: " ")
    }

    // MARK: JSON helpers

    static func record(_ value: Any?) -> [String: Any] { value as? [String: Any] ?? [:] }
    static func list(_ value: Any?) -> [Any] { value as? [Any] ?? [] }
    static func text(_ value: Any?) -> String { value as? String ?? "" }

    private static func safeName(_ value: String) -> Bool {
        !value.isEmpty && !value.unicodeScalars.contains { $0.properties.generalCategory == .control }
            && !["__proto__", "constructor", "prototype"].contains(value)
    }

    /// `!hotkeyRaw` in JavaScript: false, 0 and "" are absent hotkeys.
    private static func isFalsy(_ value: Any?) -> Bool {
        if let text = value as? String { return text.isEmpty }
        if let number = value as? NSNumber { return number.doubleValue == 0 }
        return false
    }
}
