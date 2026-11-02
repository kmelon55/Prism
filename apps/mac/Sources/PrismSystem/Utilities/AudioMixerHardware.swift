import AppKit
import CoreAudio

struct MixerApp: Identifiable, Equatable {
    let id: String
    var name: String
    var processIDs: [AudioObjectID]
    var isPlaying: Bool
}

struct MixerOutput: Identifiable, Equatable {
    let id: String // Persistent device UID, never an AudioObjectID saved across launches.
    let objectID: AudioObjectID
    let name: String
    let sampleRate: Double
}

struct MixerSnapshot {
    var apps: [MixerApp] = []
    var outputs: [MixerOutput] = []
    var defaultOutputUID: String?
}

enum MixerHAL {
    static func address(_ selector: AudioObjectPropertySelector, scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> AudioObjectPropertyAddress {
        .init(mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
    }
    static func check(_ status: OSStatus) throws {
        guard status == noErr else { throw UtilityError("Could not configure app audio. Check System Audio Recording permission in System Settings.", status: status) }
    }
    static func ids(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector,
                    scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) throws -> [UInt32] {
        var property = address(selector, scope: scope), size: UInt32 = 0
        try check(AudioObjectGetPropertyDataSize(object, &property, 0, nil, &size))
        guard size <= 1_048_576, size % 4 == 0 else { throw UtilityError("Unsupported audio format.") }
        var values = [UInt32](repeating: 0, count: Int(size) / 4)
        if !values.isEmpty {
            try values.withUnsafeMutableBytes { try check(AudioObjectGetPropertyData(object, &property, 0, nil, &size, $0.baseAddress!)) }
        }
        return Array(values.prefix(Int(size) / 4))
    }
    static func uint(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector) throws -> UInt32 {
        var property = address(selector), value: UInt32 = 0, size: UInt32 = 4
        try check(AudioObjectGetPropertyData(object, &property, 0, nil, &size, &value))
        return value
    }
    static func rate(_ object: AudioObjectID) throws -> Double {
        var property = address(kAudioDevicePropertyNominalSampleRate), value = Double(0), size: UInt32 = 8
        try check(AudioObjectGetPropertyData(object, &property, 0, nil, &size, &value))
        return value
    }
    static func string(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector) throws -> String {
        var property = address(selector), value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        try check(AudioObjectGetPropertyData(object, &property, 0, nil, &size, &value))
        guard let value else { throw UtilityError("Audio device is unavailable.") }
        return value.takeRetainedValue() as String
    }
    static func format(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector) throws -> AudioStreamBasicDescription {
        var property = address(selector), value = AudioStreamBasicDescription()
        var size = UInt32(MemoryLayout.size(ofValue: value))
        try check(AudioObjectGetPropertyData(object, &property, 0, nil, &size, &value))
        return value
    }

    @MainActor static func snapshot() throws -> MixerSnapshot {
        guard #available(macOS 14.2, *) else { return MixerSnapshot() }
        let system = AudioObjectID(kAudioObjectSystemObject)
        let outputState = try AudioOutputHardware.read()
        let outputs = outputState.devices.compactMap { device -> MixerOutput? in
            guard let uid = try? string(device.id, kAudioDevicePropertyDeviceUID),
                  !uid.hasPrefix("dev.prism.audio."), let rate = try? rate(device.id), rate > 0 else { return nil }
            return MixerOutput(id: uid, objectID: device.id, name: device.name, sampleRate: rate)
        }
        var grouped: [String: MixerApp] = [:]
        for object in try ids(system, kAudioHardwarePropertyProcessObjectList) {
            guard let rawPID = try? uint(object, kAudioProcessPropertyPID) else { continue }
            let pid = pid_t(bitPattern: rawPID)
            guard pid > 1, pid != ProcessInfo.processInfo.processIdentifier,
                  let bundleID = try? string(object, kAudioProcessPropertyBundleID), !bundleID.isEmpty else { continue }
            let running = NSRunningApplication(processIdentifier: pid)
            // Chromium/Electron helpers nested inside a bundle belong to that app, not separate mixer rows.
            let root = running?.bundleURL.flatMap(owningApp)
            let key = root.flatMap { Bundle(url: $0)?.bundleIdentifier } ?? bundleID
            guard key != Bundle.main.bundleIdentifier else { continue }
            let name = root?.deletingPathExtension().lastPathComponent ?? running?.localizedName ?? bundleID
            let playing = (try? uint(object, kAudioProcessPropertyIsRunningOutput)) == 1
            if var app = grouped[key] {
                app.processIDs.append(object); app.isPlaying = app.isPlaying || playing
                grouped[key] = app
            } else { grouped[key] = MixerApp(id: key, name: name, processIDs: [object], isPlaying: playing) }
        }
        return MixerSnapshot(apps: grouped.values.map { app in
            var app = app; app.processIDs.sort(); return app
        }.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }, outputs: outputs,
                             defaultOutputUID: outputs.first(where: { $0.objectID == outputState.selectedID })?.id)
    }

    static func owningApp(_ url: URL) -> URL? {
        var current = url, result: URL?
        while current.path != "/" {
            if current.pathExtension == "app" { result = current }
            current.deleteLastPathComponent()
        }
        return result
    }
}
