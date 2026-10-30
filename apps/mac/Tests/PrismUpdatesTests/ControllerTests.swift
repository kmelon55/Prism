import Foundation
import PrismKit
import Testing
@testable import PrismUpdates

/// A controller wired to a mock feed on its own host and a fake installed app in a temporary directory.
@MainActor
final class Harness {
    let directory = TemporaryDirectory()
    let host = "updates-\(UUID().uuidString.lowercased()).test"
    let signer = TestSigner()
    let installed: URL
    private(set) var relaunched: [URL] = []
    var controller: UpdateController!

    var feedURL: URL { URL(string: "https://\(host)/latest.json")! }
    var archiveURL: URL { URL(string: "https://\(host)/Prism_0.2.0_universal.app.tar.gz")! }
    var preferencesURL: URL { directory.url.appending(path: UpdatePreferences.fileName) }

    init(development: Bool = false, verifier: FakeVerifier = FakeVerifier()) {
        installed = makeInstalledApp(in: directory.url)
        makeController(development: development, verifier: verifier)
    }

    func makeController(development: Bool = false, verifier: FakeVerifier = FakeVerifier()) {
        let environment = UpdateEnvironment(
            currentVersion: "0.1.0", isDevelopment: development, installedApp: installed, feedURL: feedURL,
            target: "darwin-aarch64", session: MockURLProtocol.session,
            installer: UpdateInstaller(verifier: verifier, publicKey: signer.publicKey),
            workDirectory: directory.url, relaunch: { [weak self] url in self?.relaunched.append(url) }
        )
        controller = UpdateController(environment: environment, preferencesURL: preferencesURL)
    }

    /// Publishes version 0.2.0 with a correctly signed archive (or `archive`, signed as given).
    func publishUpdate(version: String = "0.2.0", archive: Data? = nil, signature: String? = nil) {
        let archive = archive ?? makeUpdateArchive(version: version)
        let feed = """
        {"version": "\(version)", "notes": "Prism \(version).", "pub_date": "2026-10-29T00:00:00Z",
         "platforms": {"darwin-aarch64": {"signature": "\(signature ?? signer.sign(archive))", "url": "\(archiveURL)"}}}
        """
        MockURLProtocol.serve(feedURL, .init(body: Data(feed.utf8)))
        MockURLProtocol.serve(archiveURL, .init(body: archive))
    }

    func publishCurrent() {
        MockURLProtocol.serve(feedURL, .init(body: Data(#"{"version": "0.1.0", "platforms": {}}"#.utf8)))
    }

    func failNetwork() {
        MockURLProtocol.serve(feedURL, .init(fails: true))
        MockURLProtocol.serve(archiveURL, .init(fails: true))
    }

    var installedVersion: String? {
        UpdateInstaller.infoPlist(installed)?["CFBundleShortVersionString"] as? String
    }

    /// Waits for background work such as automatic installation.
    func waitUntil(_ condition: () -> Bool) async {
        for _ in 0..<200 where !condition() {
            try? await Task.sleep(for: .milliseconds(20))
        }
    }
}

/// Ported from `updates.rs`, `Updates.test.tsx` and `usePaletteUpdate`, against a local mock feed.
@MainActor
@Suite(.serialized)
struct UpdateControllerTests {
    @Test func automaticInstallRequiresPersistedOptInAndAnAvailableUpdate() {
        var status = UpdateStatus(currentVersion: "0.1.0", phase: .available, automaticInstall: false)
        #expect(!status.shouldAutoInstall)
        status.automaticInstall = true
        #expect(status.shouldAutoInstall)
        for phase in [UpdateStatus.Phase.idle, .development, .checking, .current, .installing, .installed, .error] {
            status.phase = phase
            #expect(!status.shouldAutoInstall, "\(phase) must not trigger an installation")
        }
    }

    @Test func preferencesSurviveRestartAndInvalidPreferencesNeverOptIn() throws {
        let harness = Harness()
        #expect(!harness.controller.status.automaticInstall)
        try harness.controller.setAutomaticInstall(true)
        harness.makeController()
        #expect(harness.controller.status.automaticInstall)
        // Same key as the Tauri app.
        let saved = try JSONSerialization.jsonObject(with: Data(contentsOf: harness.preferencesURL)) as? [String: Any]
        #expect(saved?["automaticInstall"] as? Bool == true)
        try harness.controller.setAutomaticInstall(false)
        harness.makeController()
        #expect(!harness.controller.status.automaticInstall)
        for invalid in ["{", "{}", #"{"automaticInstall":"true"}"#] {
            try Data(invalid.utf8).write(to: harness.preferencesURL)
            harness.makeController()
            #expect(!harness.controller.status.automaticInstall, "\(invalid)")
        }
        try Data(#"{"automaticInstall":true}"#.utf8).write(to: harness.preferencesURL)
        harness.makeController()
        #expect(harness.controller.status.automaticInstall)
    }

    @Test func developmentBuildsNeverCheckOrInstall() async {
        let harness = Harness(development: true)
        harness.publishUpdate()
        let status = try? await harness.controller.check()
        #expect(status?.phase == .development)
        #expect(MockURLProtocol.requestCount(host: harness.host) == 0)
        await #expect(throws: UpdateError.development) { try await harness.controller.install() }
        harness.controller.startSchedule()
        try? await Task.sleep(for: .milliseconds(50))
        #expect(MockURLProtocol.requestCount(host: harness.host) == 0)
    }

    @Test func requiresSeparateInstallationAndRestartActions() async throws {
        let harness = Harness()
        harness.publishUpdate()
        let checked = try await harness.controller.check()
        #expect(checked.phase == .available)
        #expect(checked.version == "0.2.0")
        #expect(harness.installedVersion == "0.1.0")

        let installed = try await harness.controller.install()
        #expect(installed.phase == .installed)
        #expect(installed.version == "0.2.0")
        #expect(harness.installedVersion == "0.2.0")
        #expect(harness.relaunched.isEmpty)
        // The temporary download directory is gone.
        #expect(try FileManager.default.contentsOfDirectory(atPath: harness.directory.url.path).filter { $0.hasPrefix("prism-update-") }.isEmpty)

        try harness.controller.restart()
        #expect(harness.relaunched == [harness.installed])
        // An installed update is not checked again until restart.
        #expect(try await harness.controller.check().phase == .installed)
    }

    @Test func restartAndInstallNeedTheRightState() async {
        let harness = Harness()
        #expect(throws: UpdateError.notInstalled) { try harness.controller.restart() }
        await #expect(throws: UpdateError.noPendingUpdate) { try await harness.controller.install() }
        #expect(harness.relaunched.isEmpty)
    }

    @Test func reportsAnUpToDateApp() async throws {
        let harness = Harness()
        harness.publishCurrent()
        let status = try await harness.controller.check()
        #expect(status.phase == .current)
        #expect(status.version == nil)
        #expect(UpdateStrings.label(for: status) == "Prism is up to date.")
    }

    @Test func keepsCheckFailuresRecoverableWithoutClaimingTheAppIsCurrent() async throws {
        let harness = Harness()
        harness.failNetwork()
        let status = try await harness.controller.check()
        #expect(status.phase == .error)
        #expect(status.version == nil)
        #expect(status.error != nil)
        #expect(!status.canInstall)
        #expect(UpdateStrings.actionTitle(for: status) == "Check for updates")
        #expect(UpdateStrings.label(for: status) != "Prism is up to date.")
    }

    @Test func aTransientCheckFailureKeepsADiscoveredUpdate() async throws {
        let harness = Harness()
        harness.publishUpdate()
        _ = try await harness.controller.check()
        harness.failNetwork()
        let status = try await harness.controller.check()
        #expect(status.phase == .available)
        #expect(status.version == "0.2.0")
        #expect(status.error != nil)
        #expect(harness.controller.pending != nil)
    }

    @Test func rejectsUnsignedOrMismatchedArchivesWithARetry() async throws {
        for variant in 0..<3 {
            let harness = Harness(verifier: FakeVerifier(accepts: variant != 2))
            let archive = makeUpdateArchive(version: "0.2.0")
            switch variant {
            case 0: harness.publishUpdate(signature: TestSigner().sign(archive))
            case 1: harness.publishUpdate(archive: archive, signature: harness.signer.sign(archive + Data([0])))
            default: harness.publishUpdate()
            }
            _ = try await harness.controller.check()
            let status = try await harness.controller.install()
            #expect(status.phase == .error)
            #expect(status.version == "0.2.0")
            #expect(status.error == (variant == 2 ? UpdateError.identityChanged : .signature).message)
            #expect(status.canInstall)
            #expect(harness.installedVersion == "0.1.0")
            #expect(harness.relaunched.isEmpty)
            #expect(throws: UpdateError.notInstalled) { try harness.controller.restart() }
        }
    }

    @Test func downloadFailuresAreRetryable() async throws {
        let harness = Harness()
        harness.publishUpdate()
        _ = try await harness.controller.check()
        MockURLProtocol.serve(harness.archiveURL, .init(status: 404))
        #expect(try await harness.controller.install().phase == .error)
        harness.publishUpdate()
        #expect(try await harness.controller.install().phase == .installed)
    }

    @Test func automaticInstallationFollowsADiscoveredUpdate() async throws {
        let harness = Harness()
        try harness.controller.setAutomaticInstall(true)
        harness.publishUpdate()
        _ = try await harness.controller.check()
        await harness.waitUntil { harness.controller.status.phase == .installed }
        #expect(harness.controller.status.phase == .installed)
        #expect(harness.installedVersion == "0.2.0")
        #expect(harness.relaunched.isEmpty)
    }

    @Test func turningOnAutomaticInstallationInstallsAnAlreadyDiscoveredUpdate() async throws {
        let harness = Harness()
        harness.publishUpdate()
        _ = try await harness.controller.check()
        #expect(harness.controller.status.phase == .available)
        try harness.controller.setAutomaticInstall(true)
        await harness.waitUntil { harness.controller.status.phase == .installed }
        #expect(harness.installedVersion == "0.2.0")
        #expect(harness.relaunched.isEmpty)
    }

    @Test func operationsAreSerialized() async throws {
        let harness = Harness()
        harness.publishUpdate()
        _ = try await harness.controller.check()
        MockURLProtocol.serve(harness.archiveURL, .init(body: makeUpdateArchive(version: "0.2.0"), delay: 0.3))
        let install = Task { try await harness.controller.install() }
        await harness.waitUntil { harness.controller.status.phase == .installing }
        #expect(harness.controller.status.phase == .installing)
        await #expect(throws: UpdateError.busy) { try await harness.controller.check() }
        #expect(throws: UpdateError.busy) { try harness.controller.setAutomaticInstall(true) }
        #expect(try await install.value.phase == .installed)
        #expect(!harness.controller.status.automaticInstall)
    }

    @Test func scheduledChecksStartAfterTheInitialDelay() async {
        let harness = Harness()
        harness.publishUpdate()
        var environment = harness.controller.environment
        environment.initialDelay = .milliseconds(10)
        harness.controller = UpdateController(environment: environment, preferencesURL: harness.preferencesURL)
        #expect(MockURLProtocol.requestCount(host: harness.host) == 0)
        harness.controller.startSchedule()
        await harness.waitUntil { harness.controller.status.phase == .available }
        harness.controller.stopSchedule()
        #expect(harness.controller.status.phase == .available)
        #expect(MockURLProtocol.requestCount(host: harness.host) == 1)
    }
}

@MainActor
@Suite(.serialized)
struct UpdatesProviderTests {
    private func rows(_ harness: Harness) async -> [PaletteItem] {
        await UpdatesProvider(controller: harness.controller).results(for: "")
    }

    @Test func showsOnlyTheCheckCommandWithoutAnUpdate() async throws {
        let harness = Harness()
        let items = await rows(harness)
        #expect(items.map(\.id) == [UpdatesProvider.checkRowID])
        #expect(items[0].hiddenWhenQueryIsEmpty)
        #expect(items[0].candidate.searchAliases.contains("업데이트 확인"))
    }

    @Test func followsInstallationThroughRestart() async throws {
        let harness = Harness()
        harness.publishUpdate()
        _ = try await harness.controller.check()
        var update = try #require(await rows(harness).first)
        #expect(update.id == UpdatesProvider.updateRowID)
        #expect(update.title == "Update Prism")
        #expect(update.subtitle == "Prism 0.1.0 → 0.2.0")
        #expect(update.section == "Prism updates")
        #expect(!update.hiddenWhenQueryIsEmpty)
        #expect(update.actions.map(\.title) == ["Download and install"])

        let outcome = await update.actions[0].run()
        guard case .keepOpen = outcome else { Issue.record("expected keepOpen"); return }
        update = try #require(await rows(harness).first)
        #expect(update.title == "Restart Prism to update")
        #expect(update.actions.map(\.title) == ["Restart Prism"])
        #expect(harness.relaunched.isEmpty)

        _ = await update.actions[0].run()
        #expect(harness.relaunched == [harness.installed])
    }

    @Test func showsInstallingAndRetryRows() async throws {
        let harness = Harness(verifier: FakeVerifier(accepts: false))
        harness.publishUpdate()
        _ = try await harness.controller.check()
        let provider = UpdatesProvider(controller: harness.controller)
        let installing = provider.updateRow(UpdateStatus(currentVersion: "0.1.0", phase: .installing, version: "0.2.0", automaticInstall: false))
        #expect(installing?.title == "Installing Prism update…")
        #expect(installing?.actions.first?.title == "Installing…")
        #expect(provider.updateRow(UpdateStatus(currentVersion: "0.1.0", phase: .error, version: nil, automaticInstall: false)) == nil)

        let outcome = await provider.updateRow(harness.controller.status)!.actions[0].run()
        guard case .notify = outcome else { Issue.record("expected a failure notice"); return }
        let retry = try #require(await rows(harness).first)
        #expect(retry.title == "Retry Prism update")
        #expect(harness.installedVersion == "0.1.0")
    }

    @Test func checkCommandReportsTheResult() async throws {
        let harness = Harness()
        harness.publishCurrent()
        let check = try #require(await rows(harness).first { $0.id == UpdatesProvider.checkRowID })
        guard case .notify(let message) = await check.actions[0].run() else { Issue.record("expected notify"); return }
        #expect(message == "Prism is up to date.")

        harness.publishUpdate()
        guard case .notify(let available) = await check.actions[0].run() else { Issue.record("expected notify"); return }
        #expect(available == "A new version of Prism is available.")
        #expect(await rows(harness).first?.id == UpdatesProvider.updateRowID)
    }

    @Test func featureAddsTheProviderAndPaneWithoutNetworkInTests() async {
        let directory = TemporaryDirectory()
        let context = FakeContext(directory: directory.url)
        let feature = UpdatesFeature.make(context: context)
        #expect(feature.providers.map(\.id) == [UpdatesProvider.providerID])
        #expect(feature.settingsPanes.map(\.id) == [UpdatesFeature.settingsPaneID])
        #expect(feature.settingsPanes.first?.order == 850)
        // The test runner is not the release app, so this is a development build that never checks.
        feature.start()
        let items = await feature.providers[0].results(for: "")
        #expect(items.map(\.id) == [UpdatesProvider.checkRowID])
    }
}
