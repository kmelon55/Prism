import CoreAudio
import Foundation
import Observation

struct AudioOutputDevice: Identifiable, Equatable {
    let id: AudioDeviceID
    let name: String
}

struct AudioOutputSnapshot {
    var devices: [AudioOutputDevice]
    var selectedID: AudioDeviceID?
}

@MainActor @Observable
final class AudioOutputModel {
    private(set) var devices: [AudioOutputDevice] = []
    private(set) var selectedID: AudioDeviceID?
    private(set) var error: String?
    @ObservationIgnored private let read: () throws -> AudioOutputSnapshot
    @ObservationIgnored private let select: (AudioDeviceID) throws -> Void
    @ObservationIgnored private let observe: (@escaping @MainActor () -> Void) throws -> (() -> Void)
    @ObservationIgnored private var stopObserving: (() -> Void)?
    @ObservationIgnored private var viewers = 0

    init(read: @escaping () throws -> AudioOutputSnapshot = AudioOutputHardware.read,
         select: @escaping (AudioDeviceID) throws -> Void = AudioOutputHardware.select,
         observe: @escaping (@escaping @MainActor () -> Void) throws -> (() -> Void) = AudioOutputHardware.observe) {
        self.read = read; self.select = select; self.observe = observe
    }

    func refresh() {
        do {
            let snapshot = try read()
            devices = snapshot.devices
            selectedID = snapshot.selectedID
            error = nil
        } catch {
            devices = []; selectedID = nil
            self.error = error.localizedDescription
        }
    }

    func choose(_ id: AudioDeviceID) {
        do {
            // Re-read just before writing: a headphone or display may have disconnected since the tap.
            let current = try read()
            devices = current.devices; selectedID = current.selectedID
            guard current.devices.contains(where: { $0.id == id }) else {
                throw UtilityError("That audio device is no longer connected.")
            }
            try select(id)
            let verified = try read()
            devices = verified.devices; selectedID = verified.selectedID
            guard selectedID == id else { throw UtilityError("The audio output did not change. Try again.") }
            error = nil
        } catch {
            // Do not claim a successful switch, or restore a stale default after an uncertain write.
            refresh()
            self.error = error.localizedDescription
        }
    }

    func appear() {
        viewers += 1
        refresh()
        guard stopObserving == nil else { return }
        do { stopObserving = try observe { [weak self] in self?.refresh() } }
        catch { self.error = error.localizedDescription }
    }

    func disappear() {
        viewers = max(0, viewers - 1)
        guard viewers == 0 else { return }
        stopObserving?(); stopObserving = nil
    }
}

/// Only enumerates output devices and changes the default playback output. No recording or microphone access.
enum AudioOutputHardware {
    private static let system = AudioObjectID(kAudioObjectSystemObject)
    private static func address(_ selector: AudioObjectPropertySelector, scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
    }

    static func read() throws -> AudioOutputSnapshot {
        var property = address(kAudioHardwarePropertyDevices)
        var size: UInt32 = 0
        try check(AudioObjectGetPropertyDataSize(system, &property, 0, nil, &size))
        var ids = [AudioDeviceID](repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.size)
        if !ids.isEmpty {
            try ids.withUnsafeMutableBytes { bytes in
                try check(AudioObjectGetPropertyData(system, &property, 0, nil, &size, bytes.baseAddress!))
            }
        }
        let devices = ids.prefix(Int(size) / MemoryLayout<AudioDeviceID>.size).compactMap { id -> AudioOutputDevice? in
            // Never offer Prism's private per-app aggregate as a system default output (feedback loop).
            if let uid = try? MixerHAL.string(id, kAudioDevicePropertyDeviceUID), uid.hasPrefix("dev.prism.audio.") { return nil }
            // A device can vanish during enumeration. Omit that device, retaining the other outputs.
            var streams = address(kAudioDevicePropertyStreams, scope: kAudioDevicePropertyScopeOutput)
            var bytes: UInt32 = 0
            guard AudioObjectGetPropertyDataSize(id, &streams, 0, nil, &bytes) == noErr, bytes > 0,
                  (try? integer(id, selector: kAudioDevicePropertyDeviceIsAlive)) == 1 else { return nil }
            var nameProperty = address(kAudioObjectPropertyName)
            var name: Unmanaged<CFString>?
            var nameSize = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
            guard AudioObjectGetPropertyData(id, &nameProperty, 0, nil, &nameSize, &name) == noErr,
                  let name else { return nil }
            return AudioOutputDevice(id: id, name: name.takeRetainedValue() as String)
        }.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        let selected = try integer(system, selector: kAudioHardwarePropertyDefaultOutputDevice)
        return AudioOutputSnapshot(devices: devices, selectedID: selected == kAudioObjectUnknown ? nil : selected)
    }

    static func select(_ id: AudioDeviceID) throws {
        var property = address(kAudioHardwarePropertyDefaultOutputDevice)
        var value = id
        try check(AudioObjectSetPropertyData(system, &property, 0, nil, UInt32(MemoryLayout.size(ofValue: value)), &value),
                  message: "Could not change the audio output.")
    }

    static func observe(_ changed: @escaping @MainActor () -> Void) throws -> (() -> Void) {
        let block: AudioObjectPropertyListenerBlock = { _, _ in Task { @MainActor in changed() } }
        let selectors = [kAudioHardwarePropertyDevices, kAudioHardwarePropertyDefaultOutputDevice]
        var installed: [AudioObjectPropertySelector] = []
        do {
            for selector in selectors {
                var property = address(selector)
                try check(AudioObjectAddPropertyListenerBlock(system, &property, .main, block))
                installed.append(selector)
            }
        } catch {
            for selector in installed {
                var property = address(selector)
                AudioObjectRemovePropertyListenerBlock(system, &property, .main, block)
            }
            throw error
        }
        return {
            for selector in selectors {
                var property = address(selector)
                AudioObjectRemovePropertyListenerBlock(system, &property, .main, block)
            }
        }
    }

    private static func integer(_ id: AudioObjectID, selector: AudioObjectPropertySelector) throws -> UInt32 {
        var property = address(selector)
        var value: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        try check(AudioObjectGetPropertyData(id, &property, 0, nil, &size, &value))
        return value
    }

    private static func check(_ status: OSStatus, message: String = "Could not read audio outputs.") throws {
        guard status == noErr else { throw UtilityError(message, status: status) }
    }
}
