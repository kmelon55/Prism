import CoreAudio
import PrismAudioDSP

@MainActor
protocol MixerSession: AnyObject {
    var isApplied: Bool { get }
    func setGain(_ gain: Float)
    func poll() throws
    func stop()
}

/// One private aggregate per controlled app. Output routes never change the system's default device.
@available(macOS 14.2, *)
@MainActor
final class AudioMixerSession: MixerSession {
    private let resources = MixerResources()
    private var tap: AudioObjectID { get { resources.tap } set { resources.tap = newValue } }
    private var aggregate: AudioObjectID { get { resources.aggregate } set { resources.aggregate = newValue } }
    private var ioProc: AudioDeviceIOProcID? { get { resources.ioProc } set { resources.ioProc = newValue } }
    private var dsp: OpaquePointer? { get { resources.dsp } set { resources.dsp = newValue } }
    private let description: CATapDescription
    private(set) var isApplied = false

    init(app: MixerApp, output: MixerOutput, gain: Float) throws {
        description = CATapDescription(stereoMixdownOfProcesses: app.processIDs)
        description.name = "Prism · \(app.name)"
        description.isPrivate = true
        // The original output remains intact while permission is pending or the tap is silent.
        description.muteBehavior = .unmuted
        do {
            try MixerHAL.check(AudioHardwareCreateProcessTap(description, &tap))
            let tapUID = try MixerHAL.string(tap, kAudioTapPropertyUID)
            let config: [String: Any] = [
                kAudioAggregateDeviceNameKey: "Prism · \(app.name)",
                kAudioAggregateDeviceUIDKey: "dev.prism.audio.\(UUID().uuidString)",
                kAudioAggregateDeviceIsPrivateKey: true,
                kAudioAggregateDeviceIsStackedKey: false,
                kAudioAggregateDeviceMainSubDeviceKey: output.id,
                kAudioAggregateDeviceSubDeviceListKey: [[kAudioSubDeviceUIDKey: output.id,
                                                       kAudioSubDeviceInputChannelsKey: 0]],
                kAudioAggregateDeviceTapListKey: [[kAudioSubTapUIDKey: tapUID,
                                                  kAudioSubTapDriftCompensationKey: true]],
                kAudioAggregateDeviceTapAutoStartKey: false,
            ]
            try MixerHAL.check(AudioHardwareCreateAggregateDevice(config as CFDictionary, &aggregate))
            // Reject unsupported layouts before starting IO, including unexpected microphone inputs.
            try Self.validate(aggregate: aggregate)
            guard let state = PrismAudioDSPCreate(gain) else { throw UtilityError("Could not allocate the audio mixer.") }
            dsp = state
            try MixerHAL.check(AudioDeviceCreateIOProcID(aggregate, PrismAudioDSPCallback, UnsafeMutableRawPointer(state), &ioProc))
            try MixerHAL.check(AudioDeviceStart(aggregate, ioProc))
        } catch { stop(); throw error }
    }

    func setGain(_ gain: Float) { if let dsp { PrismAudioDSPSetGain(dsp, gain) } }

    func poll() throws {
        guard let dsp else { return }
        if PrismAudioDSPHasFault(dsp) {
            stop()
            throw UtilityError("The audio format changed. Normal app audio has been restored.")
        }
        guard !isApplied, PrismAudioDSPHasSignal(dsp) else { return }
        description.muteBehavior = .mutedWhenTapped
        var value: CATapDescription = description
        var property = MixerHAL.address(kAudioTapPropertyDescription)
        let status = withUnsafePointer(to: &value) {
            AudioObjectSetPropertyData(tap, &property, 0, nil, UInt32(MemoryLayout<CATapDescription>.size), $0)
        }
        guard status == noErr else { stop(); try MixerHAL.check(status); return }
        PrismAudioDSPArm(dsp)
        isApplied = true
    }

    func stop() {
        resources.stop()
        isApplied = false
    }

    private static func validate(aggregate: AudioObjectID) throws {
        let inputs = try MixerHAL.ids(aggregate, kAudioDevicePropertyStreams, scope: kAudioDevicePropertyScopeInput)
        let outputs = try MixerHAL.ids(aggregate, kAudioDevicePropertyStreams, scope: kAudioDevicePropertyScopeOutput)
        guard !inputs.isEmpty, !outputs.isEmpty else { throw UtilityError("Unsupported audio format.") }
        let inputFormats = try inputs.map { try MixerHAL.format($0, kAudioStreamPropertyVirtualFormat) }
        let outputFormats = try outputs.map { try MixerHAL.format($0, kAudioStreamPropertyVirtualFormat) }
        guard supports(input: inputFormats, output: outputFormats) else {
            throw UtilityError("App audio currently supports matching-rate mono or stereo devices.")
        }
    }

    static func supports(input: [AudioStreamBasicDescription], output: [AudioStreamBasicDescription]) -> Bool {
        let formats = input + output
        guard let first = formats.first, !output.isEmpty else { return false }
        let rate = first.mSampleRate
        return input.reduce(0, { $0 + $1.mChannelsPerFrame }) == 2 &&
            (1...2).contains(output.reduce(0, { $0 + $1.mChannelsPerFrame })) &&
            formats.allSatisfy {
                let interleaved = $0.mFormatFlags & kAudioFormatFlagIsNonInterleaved == 0
                return $0.mFormatID == kAudioFormatLinearPCM && $0.mBitsPerChannel == 32 &&
                    $0.mFormatFlags & kAudioFormatFlagIsFloat != 0 && $0.mFormatFlags & kAudioFormatFlagIsBigEndian == 0 &&
                    $0.mBytesPerFrame == 4 * (interleaved ? $0.mChannelsPerFrame : 1) &&
                    $0.mFramesPerPacket == 1 && $0.mSampleRate == rate && rate > 0
            }
    }
}

/// HAL resources are released even if a failed construction or app-model teardown drops the session.
@available(macOS 14.2, *)
private final class MixerResources {
    var tap: AudioObjectID = 0
    var aggregate: AudioObjectID = 0
    var ioProc: AudioDeviceIOProcID?
    var dsp: OpaquePointer?

    func stop() {
        // Stop reading before destroying the tap: mutedWhenTapped immediately returns normal playback.
        // Free callback memory only after HAL has stopped and unregistered the callback.
        if aggregate != 0, let ioProc {
            let stopped = AudioDeviceStop(aggregate, ioProc)
            let removed = AudioDeviceDestroyIOProcID(aggregate, ioProc)
            if stopped != noErr && removed != noErr {
                // Keep callback memory alive if HAL cannot prove that it stopped using it.
                // The private aggregate is still destroyed below to release the route.
                dsp = nil
            }
        }
        ioProc = nil
        if aggregate != 0 { AudioHardwareDestroyAggregateDevice(aggregate); aggregate = 0 }
        if tap != 0 { AudioHardwareDestroyProcessTap(tap); tap = 0 }
        if let dsp { PrismAudioDSPDestroy(dsp) }
        dsp = nil
    }
    deinit { stop() }
}
