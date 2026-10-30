import Foundation
import Testing
@testable import PrismBackup

/// Ports of the review half of `raycast.test.ts`.
@Suite struct RaycastPlanTests {
    static let context = RaycastImportContext(apps: [.init(path: "/Applications/Example.app", name: "Example")])

    static func physical(_ code: Int, _ modifiers: [String]) -> [String: Any] {
        ["kind": ["type": "SingleStep", "shortcut": ["modifiers": modifiers.map { ["modifier": $0] }, "key": ["type": "LayoutIndependent", "code": code]]]]
    }

    @Test(arguments: [
        ("leftHalf", "window:left-half"), ("rightHalf", "window:right-half"), ("maximize", "window:maximize"), ("centerThird", "window:center-third"),
        ("moveNextDisplay", "window:next-display"), ("movePreviousDisplay", "window:previous-display"),
        ("bottomCenterSixth", "window:bottom-center-sixth"), ("bottomLeftSixth", "window:bottom-left-sixth"),
        ("bottomRightSixth", "window:bottom-right-sixth"), ("topCenterSixth", "window:top-center-sixth"),
        ("topLeftSixth", "window:top-left-sixth"), ("topRightSixth", "window:top-right-sixth"),
    ])
    func mapsRaycastXWindowCommands(source: String, target: String) throws {
        let data: [String: Any] = ["settings": ["commands": [["id": "c:r:window-management::-::\(source)", "macosHotkey": Self.physical(18, ["Alt"]), "alias": "layout"]]]]
        let rows = try RaycastPlan.build(data, context: Self.context)
        #expect(rows.count == 2)
        #expect(rows[0].commandId == target && rows[0].category == .hotkeys && rows[0].value == "Alt+1")
        #expect(rows[1].commandId == target && rows[1].category == .aliases && rows[1].value == "layout")
        #expect(rows.allSatisfy { $0.isReady && !$0.title.hasPrefix("c:r:") })
        var disabled = Self.context
        disabled.disabled = [target]
        #expect(try RaycastPlan.build(data, context: disabled).allSatisfy { $0.reason == "Command is disabled in Prism" })
        var existing = Self.context
        existing.hotkeys = [target: "super+KeyK"]
        existing.aliases = [target: "existing"]
        #expect(try RaycastPlan.build(data, context: existing).allSatisfy { $0.conflict == true && $0.before != nil })
    }

    @Test func doesNotMapExtensionCommandsOrCustomLayoutsByLeafName() {
        for id in ["c:e:window-management::-::leftHalf", "c:r:other::-::leftHalf", "c:r:window-management::-::customLayout::=::leftHalf",
                   "c:r:window-management::-::unknownLayout"] {
            #expect(RaycastPlan.resolveCommand(key: id, path: "", apps: []) == nil)
        }
    }

    @Test(arguments: [("sleep", "system:sleep"), ("sleepDisplays", "system:sleep-displays"), ("restart", "system:restart"),
                      ("shutDown", "system:shutdown"), ("logOut", "system:log-out")])
    func mapsClassicAndPackageQualifiedPowerCommands(source: String, target: String) throws {
        for key in ["builtin_command_\(source)", "c:r:system::*::\(source)", "c:r:systemActions::*::\(source)"] {
            let rows = try RaycastPlan.build(["settings": ["commands": [["id": key, "hotkey": "control-option-0", "alias": source]]]],
                                             context: Self.context)
            #expect(rows.count == 2)
            #expect(rows.allSatisfy { $0.commandId == target && $0.isReady && $0.title != key })
        }
    }

    @Test(arguments: [("clipboardHistory", "clipboardHistory", "clipboard:open-history"), ("emoji", "searchEmoji", "prism:emoji"),
                      ("fileSearch", "searchFiles", "prism:files"), ("snippets", "searchSnippets", "prism:snippets"),
                      ("quicklinks", "searchQuicklinks", "prism:links"), ("raycastPreferences", "openPreferences", "prism:preferences"),
                      ("open-ai", "aiChat", "prism:ai-chat")])
    func mapsExistingCapabilities(package: String, command: String, target: String) {
        #expect(RaycastPlan.resolveCommand(key: "c:r:\(package)::*::\(command)", path: "", apps: []) == target)
    }

    @Test func neverMapsExtensionsWrongPackagesPrototypeKeysOrForceVariants() {
        for key in ["c:e:system::*::restart", "c:r:snippets::*::restart", "c:r:unknown::*::sleep", "c:r:__proto__::*::restart",
                    "c:r:system::*::constructor", "builtin_command_forceRestart", "c:r:system::*::restartWithoutConfirmation"] {
            #expect(RaycastPlan.resolveCommand(key: key, path: "", apps: []) == nil)
        }
    }

    @Test func commandsMissingFromTheAppAreUnsupported() throws {
        var context = Self.context
        context.commandTitles = ["system:restart": "Restart"]
        let data: [String: Any] = ["settings": ["commands": [["id": "builtin_command_restart", "alias": "reboot"],
                                                             ["id": "c:r:raycastPreferences::*::openPreferences", "alias": "prefs"]]]]
        let rows = try RaycastPlan.build(data, context: context)
        #expect(rows[0].isReady && rows[0].title == "Restart")
        #expect(rows[1].reason == "No matching Prism command or installed app")
    }

    @Test func mapsWindowsApplicationsAliasesAndQuicklinkQueries() throws {
        let plan = try RaycastPlan.build(RaycastFileTests.classic, context: Self.context)
        #expect(plan.first { $0.commandId == "window:left-half" && $0.category == .hotkeys }?.value == "Control+Alt+Left")
        let app = plan.first { $0.commandId == "app:/Applications/Example.app" && $0.category == .aliases }
        #expect(app?.value == "ex" && app?.title == "Example")
        #expect(plan.first { $0.category == .quicklinks }?.value == "https://example.com/?q={query}")
        #expect(plan.first { $0.title == "extension_unknown" }?.reason != nil)
        #expect(plan.first { $0.category == .snippets }?.entry?.keyword == ";hello")
    }

    @Test func keepsConflictsAndMarksDisabledCommandsPlaceholdersAndAbsentApps() throws {
        var context = Self.context
        context.apps = []
        context.hotkeys = ["window:left-half": "super+KeyK"]
        context.disabled = ["window:right-half"]
        let plan = try RaycastPlan.build(RaycastFileTests.classic, context: context)
        let left = plan.first { $0.commandId == "window:left-half" && $0.category == .hotkeys }
        #expect(left?.conflict == true && left?.before == "super+KeyK")
        #expect(plan.first { $0.commandId == "window:right-half" }?.reason == "Command is disabled in Prism")
        #expect(plan.first { $0.title == "Example.app" }?.reason != nil)
        let snippets = try RaycastPlan.build([["name": "Unsupported", "text": "Hi {cursor}"], ["name": "No trigger", "text": "Hello", "keyword": "hello"]],
                                             context: Self.context)
        #expect(snippets[0].reason == "Unsupported placeholder")
        #expect(snippets[1].entry?.keyword == nil)
        #expect(snippets[2].reason?.contains("prefix") == true)
    }

    @Test func detectsDuplicateImportsEquivalentAcceleratorsAndDangerousURLs() throws {
        let first = try RaycastPlan.build(RaycastFileTests.classic, context: Self.context)
        var context = Self.context
        context.entries = first.compactMap(\.entry)
        context.hotkeys = ["another": "control+alt+ArrowLeft"]
        let second = try RaycastPlan.build(RaycastFileTests.classic, context: context)
        #expect(second.filter { $0.entry != nil }.allSatisfy { $0.conflict == true })
        #expect(second.first { $0.category == .hotkeys && $0.commandId == "window:left-half" }?.conflict == true)
        #expect(RaycastPlan.canonicalHotkey("Command+Shift+K") == RaycastPlan.canonicalHotkey("Shift+Super+k"))
        #expect(RaycastPlan.sameHotkey("Control+Alt+Left", "alt+control+ArrowLeft"))
        #expect(RaycastPlan.hotkey("unknown-command-0") == nil)
        #expect(try RaycastPlan.build([["name": "Bad", "link": "javascript:alert(1)"]], context: Self.context)[0].reason == "Unsupported link")
    }

    @Test func readsPhysicalHotkeysAndRefusesMultiStepShortcuts() throws {
        let key = Self.physical(123, ["Hyper"])
        let plan = try RaycastPlan.build(["settings": ["commands": [["id": "c:r:windowManagement::*::leftHalf", "macosHotkey": key, "alias": "left"]]]],
                                         context: Self.context)
        #expect(plan[0].commandId == "window:left-half" && plan[0].value == "Control+Alt+Shift+Super+Left")
        var multi = key
        multi["kind"] = ["type": "MultiStep"]
        #expect(RaycastPlan.hotkey(multi) == nil)
        #expect(RaycastPlan.shortcut("Control+Alt+Shift+Super+Left")?.displayName == "⌃⌥⇧⌘←")
    }

    @Test func importsTheClassicLauncherHotkeyAndListsUnsupportedCategories() throws {
        let data: [String: Any] = ["builtin_package_raycastPreferences": ["preferencesGeneral": ["raycastGlobalHotkey": "command-49"]],
                                   "builtin_package_clipboardHistory": [:], "builtin_package_rootSearch": ["rootSearch": []]]
        let rows = try RaycastPlan.build(data, context: Self.context)
        #expect(rows[0].commandId == RaycastPlan.launcherID && rows[0].value == "Super+Space")
        #expect(rows.contains { $0.title == "builtin_package_clipboardHistory" && $0.reason == "This category is not supported yet" })
        #expect(throws: RaycastPlan.Failure.self) { try RaycastPlan.build(["unknown": true], context: Self.context) }
    }
}
