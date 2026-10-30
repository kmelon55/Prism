import AppKit
import Observation
import PrismKit

/// The update state shown in Settings and the palette. Same fields and phases as `UpdateStatus` in `updates.rs`.
struct UpdateStatus: Equatable, Sendable {
    enum Phase: String, Sendable {
        case idle, development, checking, current, available, installing, installed, error
    }

    var currentVersion: String
    var phase: Phase
    var version: String?
    var error: String?
    var automaticInstall: Bool

    /// Background installation starts only with the persisted opt-in and a discovered update.
    var shouldAutoInstall: Bool { automaticInstall && phase == .available }

    /// The palette shows its update row for these states, as `usePaletteUpdate` does.
    var hasPaletteRow: Bool {
        version != nil && [.available, .installing, .installed, .error].contains(phase)
    }

    /// "Prism 0.1.0", or just "Prism" for a development executable without a version.
    var currentTitle: String { currentVersion.isEmpty ? "Prism" : "Prism \(currentVersion)" }

    /// The main action installs (or retries) once a version is known.
    var canInstall: Bool { phase == .available || (phase == .error && version != nil) }
}

/// `updates-v1.json`, shared with the Tauri app: `{"automaticInstall": true}`. Anything unreadable means off.
struct UpdatePreferences: Codable, Equatable {
    var automaticInstall = false

    static let fileName = "updates-v1.json"

    init(automaticInstall: Bool = false) {
        self.automaticInstall = automaticInstall
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        automaticInstall = try container.decodeIfPresent(Bool.self, forKey: .automaticInstall) ?? false
    }
}

/// What the controller needs from the outside world, so tests can use temporary bundles and a mock feed.
struct UpdateEnvironment: Sendable {
    var currentVersion: String
    /// Development builds (another bundle ID, or not running from an app bundle) never check or install.
    var isDevelopment: Bool
    var installedApp: URL
    var feedURL: URL = UpdateFeed.url
    var target: String = UpdateFeed.target
    var session: URLSession = .shared
    var installer: UpdateInstaller
    var workDirectory: URL = FileManager.default.temporaryDirectory
    var initialDelay: Duration = .seconds(20)
    var interval: Duration = .seconds(6 * 60 * 60)
    var relaunch: @MainActor @Sendable (URL) -> Void = UpdateEnvironment.relaunch

    static func live(bundle: Bundle = .main) -> UpdateEnvironment {
        let version = bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? ""
        let release = bundle.bundleIdentifier == AppPaths.releaseBundleIdentifier && bundle.bundleURL.pathExtension == "app"
        return UpdateEnvironment(
            currentVersion: version,
            isDevelopment: !release || SemanticVersion(version) == nil,
            installedApp: bundle.bundleURL,
            installer: UpdateInstaller(
                verifier: SecurityCodeSigningVerifier(expectedIdentifier: AppPaths.releaseBundleIdentifier),
                didReplace: { url in LSRegisterURL(url as CFURL, true) }
            )
        )
    }

    /// Waits for this process to exit, then opens the (replaced) app bundle again.
    @MainActor
    static func relaunch(_ app: URL) {
        let helper = Process()
        helper.executableURL = URL(filePath: "/bin/sh")
        helper.arguments = [
            "-c", "while /bin/kill -0 \"$1\" 2>/dev/null; do /bin/sleep 0.2; done; /usr/bin/open \"$2\"",
            "prism-relaunch", String(ProcessInfo.processInfo.processIdentifier), app.path,
        ]
        do {
            try helper.run()
        } catch {
            return
        }
        NSApp.terminate(nil)
    }
}

/// One owner for update checks and installation, as in `updates.rs`: operations are serialized, a failed check
/// keeps an already-discovered update, and restarting is always a separate, explicit step.
@MainActor
@Observable
final class UpdateController {
    private(set) var status: UpdateStatus
    @ObservationIgnored private(set) var pending: UpdateRelease?
    @ObservationIgnored private var operating = false
    @ObservationIgnored private var schedule: Task<Void, Never>?
    @ObservationIgnored private let preferences: JSONFileStore<UpdatePreferences>
    @ObservationIgnored let environment: UpdateEnvironment
    /// Called after every status change, for the palette row.
    @ObservationIgnored var onChange: (() -> Void)?

    init(environment: UpdateEnvironment, preferencesURL: URL) {
        self.environment = environment
        preferences = JSONFileStore(url: preferencesURL)
        status = UpdateStatus(
            currentVersion: environment.currentVersion,
            phase: environment.isDevelopment ? .development : .idle,
            automaticInstall: preferences.load()?.automaticInstall ?? false
        )
    }

    var isBusy: Bool { operating }

    /// Checks 20 seconds after launch and then every six hours. Development builds never check.
    func startSchedule() {
        guard !environment.isDevelopment, schedule == nil else { return }
        let initialDelay = environment.initialDelay
        let interval = environment.interval
        schedule = Task { [weak self] in
            try? await Task.sleep(for: initialDelay)
            while !Task.isCancelled {
                _ = try? await self?.check()
                try? await Task.sleep(for: interval)
            }
        }
    }

    func stopSchedule() {
        schedule?.cancel()
        schedule = nil
    }

    @discardableResult
    func check() async throws(UpdateError) -> UpdateStatus {
        guard !environment.isDevelopment else { return status }
        guard !operating else { throw .busy }
        guard status.phase != .installed else { return status }
        operating = true
        let previous = status.version
        publish(.checking, version: previous)
        let result = await fetch()
        switch result {
        case .success(let update):
            pending = update
            publish(update == nil ? .current : .available, version: update?.version.description)
        case .failure(let error):
            // A transient check failure must not discard an already-discovered update.
            publish(pending == nil ? .error : .available, version: previous, error: error.message)
        }
        operating = false
        if status.shouldAutoInstall { startAutomaticInstall() }
        return status
    }

    /// Downloads, verifies and installs the pending update. Failures are reported in the status, not thrown.
    @discardableResult
    func install(automatic: Bool = false) async throws(UpdateError) -> UpdateStatus {
        guard !environment.isDevelopment else { throw .development }
        guard !operating else { throw .busy }
        if automatic && !status.shouldAutoInstall { return status }
        guard let update = pending else { throw .noPendingUpdate }
        operating = true
        defer { operating = false }
        let version = update.version.description
        publish(.installing, version: version)
        let environment = environment
        let work = environment.workDirectory.appending(path: "prism-update-\(UUID().uuidString)", directoryHint: .isDirectory)
        let result: Result<Void, UpdateError> = await Task.detached {
            defer { try? FileManager.default.removeItem(at: work) }
            do {
                try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            } catch {
                return .failure(.archive)
            }
            do throws(UpdateError) {
                let archive = try await UpdateDownloader(session: environment.session).download(update.url, into: work)
                try environment.installer.install(archive: archive, signature: update.signature, version: update.version, over: environment.installedApp)
                return .success(())
            } catch {
                return .failure(error)
            }
        }.value
        switch result {
        case .success:
            pending = nil
            publish(.installed, version: version)
        case .failure(let error):
            publish(.error, version: version, error: error.message)
        }
        return status
    }

    func restart() throws(UpdateError) {
        guard status.phase == .installed else { throw .notInstalled }
        environment.relaunch(environment.installedApp)
    }

    /// Saves the opt-in to `updates-v1.json`. Turning it on installs an already-discovered update.
    @discardableResult
    func setAutomaticInstall(_ enabled: Bool) throws -> UpdateStatus {
        guard !operating else { throw UpdateError.busy }
        try preferences.save(UpdatePreferences(automaticInstall: enabled))
        status.automaticInstall = enabled
        onChange?()
        if enabled && !environment.isDevelopment { startAutomaticInstall() }
        return status
    }

    private func startAutomaticInstall() {
        Task { _ = try? await install(automatic: true) }
    }

    private func fetch() async -> Result<UpdateRelease?, UpdateError> {
        guard let current = SemanticVersion(environment.currentVersion) else { return .failure(.invalidFeed) }
        var request = URLRequest(url: environment.feedURL, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 30)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await environment.session.data(for: request)
        } catch {
            return .failure(.network)
        }
        guard let http = response as? HTTPURLResponse else { return .failure(.network) }
        if http.statusCode == 204 { return .success(nil) }
        guard (200..<300).contains(http.statusCode) else { return .failure(.network) }
        do {
            return .success(try UpdateFeed.update(in: data, currentVersion: current, target: environment.target))
        } catch .missingPlatform {
            return .failure(.missingPlatform)
        } catch {
            return .failure(.invalidFeed)
        }
    }

    private func publish(_ phase: UpdateStatus.Phase, version: String?, error: String? = nil) {
        status.phase = phase
        status.version = version
        status.error = error
        onChange?()
    }
}
