import AppKit
import Observation

struct MixerRule: Codable, Equatable {
    var volume = 1.0
    var muted = false
    var outputUID: String?
    var gain: Float { muted ? 0 : Float(volume) }
    var isCustomized: Bool { volume != 1 || muted || outputUID != nil }
    var isValid: Bool { volume.isFinite && (0...1).contains(volume) && (outputUID == nil || outputUID?.isEmpty == false) }
}

struct MixerPreferences: Codable {
    var version = 1
    var rules: [String: MixerRule] = [:]
    var isValid: Bool { version == 1 && rules.count <= 500 && rules.allSatisfy { !$0.key.isEmpty && $0.value.isValid } }
}

@MainActor @Observable
final class AudioMixerModel {
    private(set) var enabled = false
    private(set) var apps: [MixerApp] = []
    private(set) var outputs: [MixerOutput] = []
    private(set) var rules: [String: MixerRule]
    private(set) var failures: [String: String] = [:]
    private(set) var applied: Set<String> = []
    private(set) var error: String?
    let supported: Bool
    @ObservationIgnored private let read: () throws -> MixerSnapshot
    @ObservationIgnored private let save: (MixerPreferences) throws -> Void
    @ObservationIgnored private let makeSession: (MixerApp, MixerOutput, Float) throws -> any MixerSession
    @ObservationIgnored private var sessions: [String: Entry] = [:]
    @ObservationIgnored private var timer: Timer?
    @ObservationIgnored private var viewers = 0
    @ObservationIgnored private var suspended = false
    @ObservationIgnored private var observers: [(NotificationCenter, NSObjectProtocol)] = []

    private struct Entry {
        var processes: [UInt32]
        var output: MixerOutput
        var session: any MixerSession
    }

    init(initial: MixerPreferences = MixerPreferences(), error: String? = nil, supported: Bool = true,
         read: @escaping () throws -> MixerSnapshot,
         save: @escaping (MixerPreferences) throws -> Void,
         makeSession: @escaping (MixerApp, MixerOutput, Float) throws -> any MixerSession) {
        self.rules = initial.rules; self.error = error; self.supported = supported
        self.read = read; self.save = save; self.makeSession = makeSession
    }

    convenience init(url: URL) {
        var preferences = MixerPreferences(), failure: String?
        if FileManager.default.fileExists(atPath: url.path) {
            do {
                preferences = try JSONDecoder().decode(MixerPreferences.self, from: Data(contentsOf: url))
                guard preferences.isValid else { throw CocoaError(.fileReadCorruptFile) }
            } catch {
                preferences = MixerPreferences()
                failure = SystemStrings.localized("Could not load app audio settings. Your saved file has not been changed.")
            }
        }
        let supported: Bool
        if #available(macOS 14.2, *) { supported = true } else { supported = false }
        self.init(initial: preferences, error: failure, supported: supported, read: MixerHAL.snapshot, save: { value in
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONEncoder().encode(value).write(to: url, options: .atomic)
        }, makeSession: { app, output, gain in
            guard #available(macOS 14.2, *) else { throw UtilityError("App audio requires macOS 14.2 or later.") }
            return try AudioMixerSession(app: app, output: output, gain: gain)
        })
    }

    func rule(for id: String) -> MixerRule { rules[id] ?? MixerRule() }
    var hasSessions: Bool { !sessions.isEmpty }

    func setEnabled(_ value: Bool) {
        guard supported else { return }
        enabled = value
        if !value { stopAll(); failures.removeAll() }
        refresh(); schedule()
    }

    func change(_ id: String, update: (inout MixerRule) -> Void) {
        var nextRule = rule(for: id)
        update(&nextRule)
        guard nextRule.isValid else { return }
        var next = rules
        if nextRule.isCustomized { next[id] = nextRule } else { next.removeValue(forKey: id) }
        let preferences = MixerPreferences(rules: next)
        guard preferences.isValid else { return }
        do {
            try save(preferences)
            rules = next; error = nil
            failures.removeValue(forKey: id)
            refresh(); schedule()
        } catch { self.error = SystemStrings.localized("Could not save app audio settings. The change was not applied.") }
    }

    func reset(_ id: String) { change(id) { $0 = MixerRule() } }
    func retry(_ id: String) { failures.removeValue(forKey: id); refresh() }

    func refresh() {
        guard supported, !suspended else { return }
        do {
            let snapshot = try read()
            outputs = snapshot.outputs
            apps = snapshot.apps.filter { $0.isPlaying || rules[$0.id] != nil }
            guard enabled else { return }
            let present = Set(snapshot.apps.map(\.id))
            for id in Array(sessions.keys) where !present.contains(id) || rules[id]?.isCustomized != true { stop(id) }
            for app in snapshot.apps where rules[app.id]?.isCustomized == true {
                guard failures[app.id] == nil else { continue }
                let rule = rule(for: app.id)
                let uid = rule.outputUID ?? snapshot.defaultOutputUID
                guard let output = outputs.first(where: { $0.id == uid }) else {
                    stop(app.id)
                    failures[app.id] = SystemStrings.localized("The selected output disconnected. Normal app audio has been restored.")
                    continue
                }
                if let entry = sessions[app.id], entry.processes != app.processIDs || entry.output != output { stop(app.id) }
                do {
                    if sessions[app.id] == nil {
                        // A paused app has no signal to preflight. Wait for playback without intercepting it.
                        guard app.isPlaying else { continue }
                        let session = try makeSession(app, output, rule.gain)
                        sessions[app.id] = Entry(processes: app.processIDs, output: output, session: session)
                    }
                    if let session = sessions[app.id]?.session {
                        session.setGain(rule.gain)
                        try session.poll()
                        if session.isApplied { applied.insert(app.id) } else { applied.remove(app.id) }
                    }
                } catch {
                    stop(app.id)
                    failures[app.id] = error.localizedDescription
                }
            }
        } catch {
            // A failed inventory cannot safely preserve a route whose target may have disappeared.
            stopAll()
            enabled = false
            self.error = error.localizedDescription
            schedule()
        }
    }

    func appear() { viewers += 1; refresh(); schedule() }
    func disappear() { viewers = max(0, viewers - 1); schedule() }

    func observeLifecycle() {
        guard observers.isEmpty else { return }
        let workspace = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.willSleepNotification, NSWorkspace.sessionDidResignActiveNotification] {
            observe(workspace, name) { $0.suspend() }
        }
        for name in [NSWorkspace.didWakeNotification, NSWorkspace.sessionDidBecomeActiveNotification] {
            observe(workspace, name) { $0.resume() }
        }
        observe(.default, NSApplication.willTerminateNotification) { $0.shutdown() }
    }
    func suspend() { suspended = true; stopAll(); schedule() }
    func resume() { suspended = false; refresh(); schedule() }
    func shutdown() {
        enabled = false; viewers = 0
        stopAll(); schedule()
        observers.forEach { $0.0.removeObserver($0.1) }; observers.removeAll()
    }
    private func observe(_ center: NotificationCenter, _ name: Notification.Name, action: @escaping @MainActor @Sendable (AudioMixerModel) -> Void) {
        observers.append((center, center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { if let self { action(self) } }
        }))
    }
    private func stop(_ id: String) { sessions.removeValue(forKey: id)?.session.stop(); applied.remove(id) }
    private func stopAll() { for id in Array(sessions.keys) { stop(id) } }
    private func schedule() {
        timer?.invalidate(); timer = nil
        guard !suspended, (enabled && !rules.isEmpty) || viewers > 0 else { return }
        // HAL process activity can change without the process-object list changing. Bounded polling is
        // active only while the user is using the mixer or has explicitly enabled its audio routes.
        let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
        timer.tolerance = 0.2
        RunLoop.main.add(timer, forMode: .common); self.timer = timer
    }
}
