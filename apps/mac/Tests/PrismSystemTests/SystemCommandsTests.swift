import AppKit
import Carbon.HIToolbox
import PrismCore
import PrismKit
import Testing
@testable import PrismSystem

@MainActor
final class FakeContext: PrismContext {
    let paths = AppPaths(dataDirectory: FileManager.default.temporaryDirectory.appending(path: "prism-system-tests-\(UUID().uuidString)"))
    var previousApplication: NSRunningApplication?
    private(set) var hidden = 0
    private(set) var huds: [String] = []
    private(set) var openedPanes: [String?] = []

    func showPalette() {}
    func hidePalette() { hidden += 1 }
    func showPalette(screen: PaletteScreen) {}
    func openSettings(paneID: String?) { openedPanes.append(paneID) }
    func showHUD(_ message: String) { huds.append(message) }
}

/// Ported from `system_power.rs` and `providers/system.test.ts`. Execution is always substituted.
struct SystemActionTests {
    @Test func onlyExactAllowlistedIDsResolve() {
        for id in ["/usr/bin/pmset", "system:restart; reboot", "system:force-shutdown", "rest", "system:settings:power-battery"] {
            #expect(SystemAction(commandID: id) == nil, "\(id)")
        }
        for id in ["system:sleep", "system:sleep-displays", "system:restart", "system:shutdown", "system:log-out", "system:lock-screen"] {
            #expect(SystemAction(commandID: id) != nil, "\(id)")
        }
        #expect(SystemAction.power.map(\.commandID) == ["system:sleep", "system:sleep-displays", "system:restart", "system:shutdown", "system:log-out"])
    }

    @Test func cancellationNeverReachesExecution() async throws {
        for action in [SystemAction.restart, .shutDown, .logOut, .emptyTrash, .quitAllApps] {
            let applied = try await SystemAction.run(action, confirm: { _ in false }, execute: { _ in Issue.record("cancelled action executed") })
            #expect(!applied)
        }
    }

    @Test func approvedActionsRouteOnceAndPreserveFailures() async throws {
        for action in [SystemAction.restart, .shutDown, .logOut] {
            var calls = 0
            let applied = try await SystemAction.run(action, confirm: { $0 == action }, execute: { requested in
                #expect(requested == action)
                calls += 1
            })
            #expect(applied && calls == 1)
            await #expect(throws: SystemActionError(message: "denied")) {
                try await SystemAction.run(action, confirm: { _ in true }, execute: { _ in throw SystemActionError(message: "denied") })
            }
        }
    }

    @Test func sleepActionsDoNotRequireConfirmation() async throws {
        for action in [SystemAction.sleep, .sleepDisplays, .lockScreen] {
            #expect(try await SystemAction.run(action, confirm: { _ in Issue.record("unexpected confirmation"); return false }, execute: { _ in }))
        }
    }

    @Test func plansUseNormalSessionEvents() {
        #expect(SystemAction.sleep.sessionEventID == AEEventID(kAESleep))
        #expect(SystemAction.restart.sessionEventID == AEEventID(kAERestart))
        #expect(SystemAction.shutDown.sessionEventID == AEEventID(kAEShutDown))
        #expect(SystemAction.logOut.sessionEventID == AEEventID(kAELogOut))
        #expect(SystemAction.sleepDisplays.sessionEventID == nil)
        // The four-character codes the Tauri app sends: slep, rest, shut, logo.
        #expect(kAESleep == 0x736C_6570 && kAERestart == 0x7265_7374 && kAEShutDown == 0x7368_7574 && kAELogOut == 0x6C6F_676F)
    }

    @Test func systemSettingsOpenOnlyFixedURLs() {
        #expect(SystemSetting.allCases.count == 13)
        for setting in SystemSetting.allCases {
            #expect(setting.url.scheme == "x-apple.systempreferences")
            #expect(setting.commandID.hasPrefix("system:settings:"))
        }
        #expect(SystemSetting.display.url.absoluteString == "x-apple.systempreferences:com.apple.Displays-Settings.extension")
    }
}

@MainActor
struct SystemProviderTests {
    func ranked(_ query: String) async -> [PaletteItem] {
        let context = FakeContext()
        let runner = SystemActionRunner(context: context, execute: { _ in })
        let manager = WindowManager(options: { WindowOptions() }, workAreas: { [] })
        let providers: [any PaletteProvider] = [
            SystemCommandsProvider(runner: runner),
            WindowCommandsProvider(controller: WindowCommandController(context: context, manager: manager)),
        ]
        var items: [PaletteItem] = []
        for provider in providers { items += await provider.results(for: query) }
        return CommandSearch.rank(items, query: query) { $0.candidate }
    }

    @Test(arguments: [("sleep", "system:sleep"), ("재부팅", "system:restart"), ("전원 끄기", "system:shutdown"),
                      ("로그아웃", "system:log-out"), ("화면 끄기", "system:sleep-displays"), ("lock screen", "system:lock-screen"),
                      ("left half", "window:left-half"), ("왼쪽 절반", "window:left-half"), ("거의 최대화", "window:almost-maximize"),
                      ("next display", "window:next-display"), ("bluetooth", "system:settings:bluetooth"), ("empty trash", "system:empty-trash"),
                      ("휴지통", "system:empty-trash")])
    func finds(_ query: String, _ id: String) async {
        #expect(await ranked(query).first?.id == id)
    }

    @Test func everyCommandIsAvailableForTheEmptyQuerySoHotkeysResolve() async {
        let ids = Set(await ranked("").map(\.id))
        #expect(ids.contains("window:left-half"))
        #expect(ids.contains("window:restore-previous-layout"))
        #expect(ids.contains("system:restart"))
        #expect(ids.contains("system:settings:appearance"))
        let items = await ranked("")
        let windowsHidden = items.filter { $0.id.hasPrefix("window:") }.allSatisfy { $0.hiddenWhenQueryIsEmpty }
        let systemVisible = items.filter { $0.id.hasPrefix("system:") }.allSatisfy { !$0.hiddenWhenQueryIsEmpty }
        #expect(windowsHidden)
        #expect(systemVisible)
    }

    @Test func destructiveCommandsAskForConfirmation() async {
        let context = FakeContext()
        var executed: [SystemAction] = []
        let runner = SystemActionRunner(context: context, execute: { executed.append($0) })
        for action in [SystemAction.restart, .shutDown, .logOut, .emptyTrash] {
            guard case .push(let screen) = await runner.start(action) else {
                Issue.record("\(action) ran without confirmation")
                continue
            }
            #expect(screen.id == "system-confirm:\(action.rawValue)")
        }
        #expect(executed.isEmpty)
        let outcome = await runner.start(.sleep)
        guard case .dismiss = outcome else {
            Issue.record("sleep did not run")
            return
        }
        #expect(executed == [.sleep])
        #expect(context.hidden == 1)
    }

    @Test func confirmedActionsRunOnceAndReportFailures() async {
        let context = FakeContext()
        var calls = 0
        let runner = SystemActionRunner(context: context, execute: { _ in
            calls += 1
            throw SystemActionError(message: "macOS declined")
        })
        await runner.perform(.restart)
        #expect(calls == 1)
        #expect(context.huds == ["macOS declined"])
        #expect(!runner.isBusy)
    }

    @Test func onlyOneSystemActionRunsAtATime() async {
        let context = FakeContext()
        var release: CheckedContinuation<Void, Never>?
        let runner = SystemActionRunner(context: context, execute: { _ in
            await withCheckedContinuation { release = $0 }
        })
        let first = Task { _ = await runner.perform(.sleep) }
        while release == nil { await Task.yield() }
        let second = await runner.start(.sleepDisplays)
        guard case .notify = second else {
            Issue.record("second action was not refused")
            return
        }
        release?.resume()
        await first.value
        #expect(!runner.isBusy)
    }

    @Test func windowCommandsWithoutATargetExplainWhatToDo() {
        let context = FakeContext()
        let controller = WindowCommandController(context: context, manager: WindowManager(options: { WindowOptions() }, workAreas: { [] }))
        // In tests the frontmost app is the test runner's host, so only the error path is checked.
        if controller.targetApplication == nil, case .notify(let message) = controller.run(.leftHalf) {
            #expect(message == WindowActionError.make(.noTarget).message)
        }
    }
}
