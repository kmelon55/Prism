// Adapted from Whisp. Copyright (c) 2026 Whisp contributors. MIT; see Resources/LICENSE-Whisp.txt.
import AVFoundation
import Foundation

@MainActor
protocol DictationRecording: AnyObject {
    var onLevel: ((Double) -> Void)? { get set }
    var onFailure: ((String) -> Void)? { get set }
    func start() async throws
    /// Stops recording and returns the WAV file, or nil when nothing was recording.
    func stop() -> URL?
}

/// Records 16 kHz mono 16-bit PCM WAV and reports a smoothed level every 40 ms.
@MainActor
final class AudioRecorder: NSObject, @preconcurrency AVAudioRecorderDelegate, DictationRecording {
    var onFailure: ((String) -> Void)?
    var onLevel: ((Double) -> Void)?

    private var recorder: AVAudioRecorder?
    private var meterTimer: Timer?
    private var outputURL: URL?
    private var smoothedLevel = 0.08

    func start() async throws {
        guard await Self.requestMicrophoneAccess() else { throw AudioRecorderError.permissionDenied }
        try Task.checkCancellation()
        guard AVCaptureDevice.default(for: .audio) != nil else { throw AudioRecorderError.couldNotStart }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("prism-dictation-\(UUID().uuidString).wav")
        let settings: [String: Any] = [
            AVFormatIDKey: Int(kAudioFormatLinearPCM),
            AVSampleRateKey: 16_000.0,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsFloatKey: false,
        ]
        var started = false
        defer { if !started { try? FileManager.default.removeItem(at: url) } }
        let recorder = try AVAudioRecorder(url: url, settings: settings)
        recorder.isMeteringEnabled = true
        recorder.delegate = self
        guard recorder.prepareToRecord(), recorder.record() else { throw AudioRecorderError.couldNotStart }
        do { try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path) } catch {
            recorder.stop()
            throw error
        }
        started = true
        self.recorder = recorder
        outputURL = url
        smoothedLevel = 0.08
        meterTimer?.invalidate()
        meterTimer = Timer.scheduledTimer(withTimeInterval: 0.04, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.sampleLevel() }
        }
    }

    func stop() -> URL? {
        meterTimer?.invalidate()
        meterTimer = nil
        let active = recorder
        recorder = nil
        active?.stop()
        smoothedLevel = 0.08
        onLevel?(0)
        defer { outputURL = nil }
        return outputURL
    }

    func audioRecorderDidFinishRecording(_ recorder: AVAudioRecorder, successfully flag: Bool) {
        guard self.recorder === recorder else { return }
        onFailure?(String(localized: "The microphone disconnected, so recording stopped.", bundle: .module))
    }

    func audioRecorderEncodeErrorDidOccur(_ recorder: AVAudioRecorder, error: Error?) {
        guard self.recorder === recorder else { return }
        onFailure?(String(localized: "An error occurred while recording from the microphone.", bundle: .module))
    }

    private func sampleLevel() {
        guard let recorder else { return }
        recorder.updateMeters()
        let power = Double(recorder.averagePower(forChannel: 0))
        let normalized = max(0.055, min(0.92, pow(10, power / 42) * 1.08))
        let response = normalized > smoothedLevel ? 0.58 : 0.2
        smoothedLevel += (normalized - smoothedLevel) * response
        onLevel?(smoothedLevel)
    }

    static func requestMicrophoneAccess() async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: true
        case .notDetermined: await AVCaptureDevice.requestAccess(for: .audio)
        default: false
        }
    }
}

enum AudioRecorderError: LocalizedError {
    case permissionDenied, couldNotStart

    var errorDescription: String? {
        switch self {
        case .permissionDenied: String(localized: "Allow Prism to use the microphone in System Settings.", bundle: .module)
        case .couldNotStart: String(localized: "Could not start recording from the microphone.", bundle: .module)
        }
    }
}
