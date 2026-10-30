import AppKit
import ApplicationServices
import Carbon.HIToolbox
import Observation
import PrismKit

/// Automatic snippet expansion. Typing a saved keyword such as `;email` followed by a space replaces it with the
/// snippet text.
///
/// A listen-only session event tap on the main run loop feeds the matcher; it never delays or changes typing.
/// On a match, Prism deletes the keyword and the space with Backspace and pastes the snippet followed by the
/// space, then restores the previous clipboard. Nothing is installed while expansion is off. Matching runs only
/// with an ASCII keyboard layout: Korean and other input methods compose text the tap cannot see, so keys typed
/// with them reset the match. Secure input, excluded apps, modifier shortcuts, clicks and app switches reset too.
@MainActor
@Observable
final class SnippetExpander {
    private(set) var config = SnippetExpansionConfig()
    private(set) var isActive = false
    private(set) var registeredCount = 0
    private(set) var lastError: String?

    @ObservationIgnored private let store: JSONFileStore<SnippetExpansionConfig>
    @ObservationIgnored private let library: LibraryModel
    @ObservationIgnored private var snippets: [ExpansionSnippet] = []
    @ObservationIgnored private var matcher = SnippetMatcher()
    @ObservationIgnored private var tap: CFMachPort?
    @ObservationIgnored private var runLoopSource: CFRunLoopSource?
    @ObservationIgnored private var permissionTimer: Timer?
    @ObservationIgnored private var observers: [NSObjectProtocol] = []
    @ObservationIgnored private var targetPID: pid_t = 0
    @ObservationIgnored private var isReplacing = false
    /// Marks events Prism posts so the tap ignores them.
    static let eventMarker: Int64 = 0x5052_534D_534E_4950 // "PRSMSNIP"

    init(configURL: URL, library: LibraryModel) {
        store = JSONFileStore(url: configURL)
        self.library = library
        if FileManager.default.fileExists(atPath: configURL.path) {
            if let loaded = store.load(), loaded.isValid {
                config = loaded
            } else {
                lastError = L10n.tr("Could not read snippet settings. Expansion is off.")
            }
        }
    }

    static var hasAccessibility: Bool { AXIsProcessTrusted() }
    static var hasInputMonitoring: Bool { CGPreflightListenEventAccess() }

    /// Called from `FeatureContribution.start`. Installs nothing unless expansion is on.
    func start() {
        observers.append(NotificationCenter.default.addObserver(forName: LibraryModel.didChange, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.reloadSnippets() }
        })
        let workspace = NSWorkspace.shared.notificationCenter
        observers.append(workspace.addObserver(forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.matcher.reset() }
        })
        Task {
            await library.loadIfNeeded()
            reloadSnippets()
            update()
        }
    }

    func setEnabled(_ enabled: Bool) {
        var next = config
        next.enabled = enabled
        save(next)
        if enabled && (!Self.hasAccessibility || !Self.hasInputMonitoring) { requestPermissions() }
    }

    func setExcludedApps(_ apps: [String]) {
        var next = config
        next.excludedApps = Array(NSOrderedSet(array: apps.filter(SnippetExpansionConfig.isValidExclusion))).compactMap { $0 as? String }
            .prefix(SnippetExpansionConfig.maxExclusions).map { $0 }
        save(next)
    }

    private func save(_ next: SnippetExpansionConfig) {
        // Turn off at once, even when saving fails.
        if !next.enabled { config.enabled = false; update() }
        do {
            try store.save(next)
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: store.url.path)
            config = next
            lastError = nil
        } catch {
            lastError = L10n.tr("Settings could not be saved.")
        }
        update()
    }

    func requestPermissions() {
        if !Self.hasAccessibility { Permissions.requestAccessibility() }
        if !Self.hasInputMonitoring { CGRequestListenEventAccess() }
        update()
    }

    func reloadSnippets() {
        matcher.reset()
        snippets = SnippetRegistry.build(library.entries)
        registeredCount = snippets.count
    }

    /// Installs or removes the tap to match the setting and permissions. While on but missing permission,
    /// checks again every two seconds.
    func update() {
        let wanted = config.enabled && Self.hasAccessibility && Self.hasInputMonitoring
        if wanted && tap == nil { installTap() }
        if !wanted && tap != nil { removeTap() }
        isActive = tap != nil
        if config.enabled && !isActive {
            if permissionTimer == nil {
                permissionTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
                    MainActor.assumeIsolated { self?.update() }
                }
            }
        } else {
            permissionTimer?.invalidate()
            permissionTimer = nil
        }
    }

    func stop() {
        removeTap()
        permissionTimer?.invalidate()
        permissionTimer = nil
        observers.forEach { NotificationCenter.default.removeObserver($0); NSWorkspace.shared.notificationCenter.removeObserver($0) }
        observers = []
    }

    // MARK: Event tap

    private func installTap() {
        let types: [CGEventType] = [.keyDown, .leftMouseDown, .rightMouseDown, .otherMouseDown]
        let mask = types.reduce(CGEventMask(0)) { $0 | (CGEventMask(1) << $1.rawValue) }
        let callback: CGEventTapCallBack = { _, type, event, userInfo in
            guard let userInfo else { return Unmanaged.passUnretained(event) }
            let expander = Unmanaged<SnippetExpander>.fromOpaque(userInfo).takeUnretainedValue()
            // The source is on the main run loop.
            MainActor.assumeIsolated { expander.handle(type: type, event: event) }
            return Unmanaged.passUnretained(event)
        }
        guard let tap = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .tailAppendEventTap, options: .listenOnly,
                                          eventsOfInterest: mask, callback: callback,
                                          userInfo: Unmanaged.passUnretained(self).toOpaque())
        else {
            lastError = L10n.tr("Input monitoring could not start. Review permissions and retry.")
            return
        }
        let source = CFMachPortCreateRunLoopSource(nil, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        self.tap = tap
        runLoopSource = source
        matcher.reset()
    }

    private func removeTap() {
        if let tap { CGEvent.tapEnable(tap: tap, enable: false); CFMachPortInvalidate(tap) }
        if let runLoopSource { CFRunLoopRemoveSource(CFRunLoopGetMain(), runLoopSource, .commonModes) }
        tap = nil
        runLoopSource = nil
        matcher.reset()
        isActive = false
    }

    private func handle(type: CGEventType, event: CGEvent) {
        switch type {
        case .tapDisabledByTimeout, .tapDisabledByUserInput:
            matcher.reset()
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
        case .keyDown:
            handleKey(event)
        default:
            matcher.reset()
        }
    }

    private func handleKey(_ event: CGEvent) {
        guard !isReplacing else { return }
        if event.getIntegerValueField(.eventSourceUserData) == Self.eventMarker { return }
        let flags = event.flags
        let blocked: CGEventFlags = [.maskCommand, .maskControl, .maskAlternate, .maskSecondaryFn]
        let isRepeat = event.getIntegerValueField(.keyboardEventAutorepeat) != 0
        let character = Self.character(of: event)
        guard flags.intersection(blocked).isEmpty, !isRepeat, let character else {
            matcher.reset()
            return
        }
        // Context checks only when a keyword could be in progress or is starting, so ordinary typing stays cheap.
        let mayMatter = !matcher.isIdle || character.asciiValue.map(LibraryValidation.keywordPrefixes.contains) == true
        guard mayMatter else { return }
        let front = NSWorkspace.shared.frontmostApplication
        if matcher.isIdle { targetPID = front?.processIdentifier ?? 0 }
        let guards = ExpansionGuards(
            enabled: config.enabled,
            permissions: true,
            directInput: Self.isDirectASCIIInput(),
            secure: IsSecureEventInputEnabled(),
            excluded: config.excludes(front?.bundleIdentifier),
            synthetic: event.getIntegerValueField(.eventSourceUnixProcessID) == Int64(ProcessInfo.processInfo.processIdentifier),
            focusMatches: front?.processIdentifier == targetPID
        )
        // Only the space expands. Return and Tab often submit or move focus before Prism could replace text.
        if character == "\t" || character == "\n" {
            matcher.reset()
            return
        }
        guard let index = matcher.feed(character, snippets: snippets, safe: guards.isSafe) else { return }
        let snippet = snippets[index]
        replace(keyword: snippet.keyword, with: snippet.text + " ", pid: targetPID)
    }

    /// The typed character for plain text keys, or nil for navigation, deletion and function keys.
    private static func character(of event: CGEvent) -> Character? {
        var length = 0
        var units = [UniChar](repeating: 0, count: 4)
        event.keyboardGetUnicodeString(maxStringLength: units.count, actualStringLength: &length, unicodeString: &units)
        guard length > 0 else { return nil }
        let string = String(utf16CodeUnits: units, count: length)
        guard string.count == 1, var character = string.first else { return nil }
        if character == "\r" { character = "\n" }
        if let ascii = character.asciiValue, (ascii < 32 && character != "\t" && character != "\n") || ascii == 127 { return nil }
        return character
    }

    /// True for ASCII-capable keyboard layouts (ABC, U.S., Dvorak, …). Input methods such as 2-Set Korean report
    /// a different source type, so typing with them never starts or continues a match.
    static func isDirectASCIIInput() -> Bool {
        guard let source = TISCopyCurrentKeyboardInputSource()?.takeRetainedValue() else { return false }
        func property(_ key: CFString) -> AnyObject? {
            guard let pointer = TISGetInputSourceProperty(source, key) else { return nil }
            return Unmanaged<AnyObject>.fromOpaque(pointer).takeUnretainedValue()
        }
        let type = property(kTISPropertyInputSourceType) as? String
        let ascii = (property(kTISPropertyInputSourceIsASCIICapable) as? NSNumber)?.boolValue ?? false
        return type == (kTISTypeKeyboardLayout as String) && ascii
    }

    // MARK: Replacement

    private func replace(keyword: String, with text: String, pid: pid_t) {
        isReplacing = true
        matcher.reset()
        let pasteboard = NSPasteboard.general
        let saved = PasteboardSnapshot(pasteboard)
        Task {
            defer { isReplacing = false }
            // Let the space reach the target before deleting it.
            try? await Task.sleep(for: .milliseconds(30))
            guard NSWorkspace.shared.frontmostApplication?.processIdentifier == pid, !IsSecureEventInputEnabled() else { return }
            let source = CGEventSource(stateID: .privateState)
            source?.userData = Self.eventMarker
            for _ in 0..<(keyword.utf16.count + 1) {
                Self.post(key: CGKeyCode(kVK_Delete), flags: [], source: source)
            }
            pasteboard.clearContents()
            pasteboard.declareTypes([.string, Self.transientType], owner: nil)
            pasteboard.setString(text, forType: .string)
            pasteboard.setString("", forType: Self.transientType)
            let changeCount = pasteboard.changeCount
            try? await Task.sleep(for: .milliseconds(20))
            Self.post(key: CGKeyCode(kVK_ANSI_V), flags: .maskCommand, source: source)
            // Restore once the target has read the clipboard, unless something else changed it meanwhile.
            try? await Task.sleep(for: .milliseconds(350))
            if pasteboard.changeCount == changeCount { saved.restore(to: pasteboard) }
        }
    }

    /// `org.nspasteboard.TransientType` tells clipboard managers, including Prism's history, to skip this item.
    static let transientType = NSPasteboard.PasteboardType("org.nspasteboard.TransientType")
    nonisolated static var transientTypeForTests: NSPasteboard.PasteboardType { NSPasteboard.PasteboardType("org.nspasteboard.TransientType") }

    private static func post(key: CGKeyCode, flags: CGEventFlags, source: CGEventSource?) {
        let down = CGEvent(keyboardEventSource: source, virtualKey: key, keyDown: true)
        let up = CGEvent(keyboardEventSource: source, virtualKey: key, keyDown: false)
        down?.flags = flags
        up?.flags = flags
        down?.post(tap: .cghidEventTap)
        up?.post(tap: .cghidEventTap)
    }
}

/// Every item and type on the clipboard, so expansion can put the user's clipboard back.
@MainActor
struct PasteboardSnapshot {
    private let items: [[NSPasteboard.PasteboardType: Data]]

    init(_ pasteboard: NSPasteboard) {
        // Bounded: very large clipboards (images, files) are kept by reference types only up to 32 MB in total.
        var total = 0
        var items: [[NSPasteboard.PasteboardType: Data]] = []
        for item in pasteboard.pasteboardItems ?? [] {
            var copy: [NSPasteboard.PasteboardType: Data] = [:]
            for type in item.types {
                guard let data = item.data(forType: type), total + data.count <= 32 * 1024 * 1024 else { continue }
                total += data.count
                copy[type] = data
            }
            items.append(copy)
        }
        self.items = items
    }

    func restore(to pasteboard: NSPasteboard) {
        pasteboard.clearContents()
        guard !items.isEmpty else { return }
        let restored = items.map { types -> NSPasteboardItem in
            let item = NSPasteboardItem()
            for (type, data) in types { item.setData(data, forType: type) }
            // Already in clipboard history; do not record it again.
            item.setData(Data(), forType: SnippetExpander.transientType)
            return item
        }
        pasteboard.writeObjects(restored)
    }
}
