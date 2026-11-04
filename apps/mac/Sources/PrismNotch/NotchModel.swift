import AppKit
import Observation
import PrismKit

@MainActor
@Observable
final class NotchModel {
    private(set) var preferences: NotchPreferences
    private(set) var error: String?
    let widgets: [NotchWidget]
    @ObservationIgnored var onChange: (() -> Void)?
    @ObservationIgnored var onTimerFinished: (() -> Void)?
    @ObservationIgnored private let save: (NotchPreferences) throws -> Void
    @ObservationIgnored private var completionTimer: Timer?
    @ObservationIgnored private var started = false

    init(widgets: [NotchWidget], initial: NotchPreferences = NotchPreferences(), error: String? = nil,
         save: @escaping (NotchPreferences) throws -> Void) {
        self.widgets = widgets
        self.preferences = initial
        self.error = error
        self.save = save
    }

    convenience init(widgets: [NotchWidget], url: URL) {
        var initial = NotchPreferences()
        var failure: String?
        if FileManager.default.fileExists(atPath: url.path) {
            do {
                let loaded = try JSONDecoder().decode(NotchPreferences.self, from: Data(contentsOf: url))
                guard loaded.isValid else { throw CocoaError(.fileReadCorruptFile) }
                initial = loaded
            } catch { failure = N("Could not load notch settings. Your saved file has not been changed.") }
        }
        self.init(widgets: widgets, initial: initial, error: failure) { value in
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONEncoder().encode(value).write(to: url, options: .atomic)
        }
    }

    var availableIDs: [String] { ["timer"] + widgets.map(\.id) }
    var visibleIDs: [String] {
        var seen = Set<String>()
        return preferences.widgets.filter { availableIDs.contains($0) && seen.insert($0).inserted }
    }
    func selectedID(for selection: String) -> String? { visibleIDs.contains(selection) ? selection : visibleIDs.first }
    var activeWidget: NotchWidget? {
        // A finished timer stays visible until acknowledged, including while Keep Awake is active.
        guard preferences.countdown.phase != .finished else { return nil }
        return widgets.filter {
            visibleIDs.contains($0.id) && $0.activity() != nil
                && (preferences.countdown.phase == .idle || $0.activityPriority >= 0)
        }.sorted { $0.activityPriority > $1.activityPriority }.first
    }
    var hasActivity: Bool { preferences.countdown.phase != .idle || activeWidget != nil }

    func start() {
        guard !started else { return }
        started = true
        refreshTimer(notify: false)
        scheduleCompletion()
    }

    @discardableResult
    func change(_ update: (inout NotchPreferences) -> Void) -> Bool {
        var next = preferences
        update(&next)
        do {
            try save(next)
            preferences = next
            error = nil
            scheduleCompletion()
            onChange?()
            return true
        } catch {
            self.error = N("Could not save notch settings. Try again.")
            return false
        }
    }

    func setEnabled(_ enabled: Bool) { _ = change { $0.enabled = enabled } }

    func setDisplay(_ target: NotchDisplayTarget, selected: Bool, connected: [NotchDisplay]) {
        change { $0.displays.set(target, selected: selected, connected: connected) }
    }

    /// Upgrade the old transient CGDisplayID once that display is connected, retaining offline choices.
    func upgradeDisplayIDs(using connected: [NotchDisplay]) {
        let targets = preferences.displays.targets.map { target in
            connected.first(where: { target.matches($0) })?.target ?? target
        }
        if targets != preferences.displays.targets { change { $0.displays.targets = targets } }
    }

    func stop() {
        started = false
        completionTimer?.invalidate()
        completionTimer = nil
    }

    func setWidget(_ id: String, visible: Bool) {
        guard availableIDs.contains(id) else { return }
        change {
            $0.widgets.removeAll { $0 == id }
            if visible { $0.widgets.append(id) }
        }
    }

    func moveWidget(_ id: String, by offset: Int) {
        var ids = visibleIDs
        guard let index = ids.firstIndex(of: id), ids.indices.contains(index + offset) else { return }
        ids.swapAt(index, index + offset)
        change { $0.widgets = ids }
    }

    /// Drag-to-reorder: puts `id` where `target` is, shifting the tools in between.
    func moveWidget(_ id: String, to target: String) {
        var ids = visibleIDs
        guard id != target, let from = ids.firstIndex(of: id), let to = ids.firstIndex(of: target) else { return }
        ids.remove(at: from)
        ids.insert(id, at: to)
        change { $0.widgets = ids }
    }

    func startTimer(minutes: Int, now: Date = Date()) {
        guard preferences.countdown.phase == .idle else { return }
        change { $0.pomodoro = nil; $0.countdown.start(minutes: minutes, now: now) }
    }
    func startPomodoro(now: Date = Date()) {
        guard preferences.countdown.phase == .idle else { return }
        change {
            $0.pomodoro = NotchPomodoro()
            $0.countdown.start(minutes: 25, now: now)
        }
    }
    func nextPomodoro(now: Date = Date()) {
        guard preferences.countdown.phase == .finished, let next = preferences.pomodoro?.next else { return }
        change {
            $0.pomodoro = next
            $0.countdown.start(minutes: next.minutes, now: now)
        }
    }
    func pauseTimer(now: Date = Date()) {
        // Finishing at the pause boundary must still count a completed focus session exactly once.
        if preferences.countdown.phase == .running, preferences.countdown.remaining(at: now) <= 0 {
            refreshTimer(now: now)
        } else { change { $0.countdown.pause(now: now) } }
    }
    func resumeTimer(now: Date = Date()) { change { $0.countdown.resume(now: now) } }
    func cancelTimer() { change { $0.countdown.cancel(); $0.pomodoro = nil } }

    func refreshTimer(now: Date = Date(), notify: Bool = true) {
        var timer = preferences.countdown
        guard timer.finishIfNeeded(now: now) else { return }
        if change({ $0.countdown = timer; $0.pomodoro?.finish() }), notify { onTimerFinished?() }
    }

    private func scheduleCompletion() {
        completionTimer?.invalidate()
        completionTimer = nil
        guard started, preferences.countdown.phase == .running, let deadline = preferences.countdown.deadline else { return }
        // One wakeup at the deadline; the view owns second-by-second display updates only while visible.
        let timer = Timer(timeInterval: max(0.1, deadline.timeIntervalSinceNow), repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.refreshTimer() }
        }
        RunLoop.main.add(timer, forMode: .common)
        completionTimer = timer
    }

    func title(for id: String) -> String { id == "timer" ? N("Timer") : widgets.first { $0.id == id }?.title ?? id }
    func symbol(for id: String) -> String { id == "timer" ? "timer" : widgets.first { $0.id == id }?.systemImage ?? "square.grid.2x2" }
}

func N(_ value: String) -> String { String(localized: String.LocalizationValue(value), bundle: .module.prismLocalized) }
