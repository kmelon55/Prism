import Foundation

/// Pointer entry never takes keyboard focus. A deliberate close suppresses hover until the next entry.
struct NotchPresentation: Equatable {
    enum Mode { case compact, preview, expanded }
    private(set) var mode = Mode.compact
    private(set) var isPinned = false
    private(set) var suppressHover = false

    mutating func preview() {
        guard mode == .compact, !suppressHover else { return }
        mode = .preview
    }

    mutating func open() { mode = .expanded; suppressHover = false }

    mutating func close() {
        mode = .compact
        isPinned = false
        suppressHover = true
    }

    mutating func toggle() {
        if mode == .expanded { close() } else { open() }
    }

    mutating func togglePin() {
        mode = .expanded
        isPinned.toggle()
    }

    mutating func leave() {
        suppressHover = false
        if mode == .preview { mode = .compact }
    }

    mutating func outsideClick() { if !isPinned { close() } }
}

struct NotchCountdown: Codable, Equatable {
    enum Phase: String, Codable { case idle, running, paused, finished }
    var phase = Phase.idle
    var duration: TimeInterval = 25 * 60
    var deadline: Date?
    var pausedRemaining: TimeInterval = 0

    func remaining(at now: Date) -> TimeInterval {
        switch phase {
        case .running: max(0, min(duration, (deadline ?? now).timeIntervalSince(now)))
        case .paused: pausedRemaining
        case .idle: duration
        case .finished: 0
        }
    }

    mutating func start(minutes: Int, now: Date) {
        duration = TimeInterval(min(180, max(1, minutes)) * 60)
        deadline = now.addingTimeInterval(duration)
        pausedRemaining = 0
        phase = .running
    }

    mutating func pause(now: Date) {
        guard phase == .running else { return }
        if finishIfNeeded(now: now) { return }
        pausedRemaining = remaining(at: now)
        deadline = nil
        phase = .paused
    }

    mutating func resume(now: Date) {
        guard phase == .paused else { return }
        deadline = now.addingTimeInterval(pausedRemaining)
        phase = .running
    }

    @discardableResult
    mutating func finishIfNeeded(now: Date) -> Bool {
        guard phase == .running, remaining(at: now) <= 0 else { return false }
        phase = .finished
        deadline = nil
        pausedRemaining = 0
        return true
    }

    mutating func cancel() { phase = .idle; deadline = nil; pausedRemaining = 0 }

    var isValid: Bool {
        duration.isFinite && (60...10_800).contains(duration)
            && pausedRemaining.isFinite && (0...10_800).contains(pausedRemaining)
            && (phase != .running || deadline?.timeIntervalSince1970.isFinite == true)
            && (phase != .paused || pausedRemaining > 0)
    }
}

/// Shares the durable countdown; the next session starts only after the user acknowledges completion.
struct NotchPomodoro: Codable, Equatable {
    enum Stage: String, Codable { case focus, shortBreak, longBreak }
    var stage = Stage.focus
    var completed = 0

    var minutes: Int {
        switch stage { case .focus: 25; case .shortBreak: 5; case .longBreak: 15 }
    }
    var isValid: Bool { (0...4).contains(completed) }
    mutating func finish() { if stage == .focus { completed = min(4, completed + 1) } }
    var next: Self {
        var result = self
        switch stage {
        case .focus: result.stage = completed == 4 ? .longBreak : .shortBreak
        case .shortBreak: result.stage = .focus
        case .longBreak: result.stage = .focus; result.completed = 0
        }
        return result
    }
}

struct NotchPreferences: Codable, Equatable {
    var version = 1
    var enabled = false
    var hoverPreview = true
    var displays = NotchDisplays()
    var widgets = ["timer", "clipboard", "notes", "dictation"]
    var countdown = NotchCountdown()
    var pomodoro: NotchPomodoro?

    var isValid: Bool { version == 1 && countdown.isValid && displays.isValid && (pomodoro?.isValid ?? true) }

    init() {}
    private enum CodingKeys: String, CodingKey { case version, enabled, hoverPreview, screenID, displays, widgets, countdown, pomodoro }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        version = try values.decode(Int.self, forKey: .version)
        enabled = try values.decode(Bool.self, forKey: .enabled)
        hoverPreview = try values.decode(Bool.self, forKey: .hoverPreview)
        widgets = try values.decode([String].self, forKey: .widgets)
        countdown = try values.decode(NotchCountdown.self, forKey: .countdown)
        pomodoro = try values.decodeIfPresent(NotchPomodoro.self, forKey: .pomodoro)
        if let selection = try values.decodeIfPresent(NotchDisplays.self, forKey: .displays) {
            displays = selection
        } else if let legacy = try values.decodeIfPresent(UInt32.self, forKey: .screenID) {
            displays = NotchDisplays(mode: .selected, targets: [.init(id: "legacy:\(legacy)", name: "")])
        }
    }

    func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(version, forKey: .version)
        try values.encode(enabled, forKey: .enabled)
        try values.encode(hoverPreview, forKey: .hoverPreview)
        try values.encode(displays, forKey: .displays)
        try values.encode(widgets, forKey: .widgets)
        try values.encode(countdown, forKey: .countdown)
        try values.encodeIfPresent(pomodoro, forKey: .pomodoro)
    }
}
