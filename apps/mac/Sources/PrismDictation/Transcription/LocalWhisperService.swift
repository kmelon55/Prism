// Adapted from Whisp. Copyright (c) 2026 Whisp contributors. MIT; see Resources/LICENSE-Whisp.txt.
import Foundation

/// Serializes launch and cancellation. No pipe that can fill while awaiting exit.
private final class WhisperProcess: @unchecked Sendable {
    let process = Process()
    private let lock = NSLock()
    private var cancelled = false

    func launch() throws {
        lock.lock(); defer { lock.unlock() }
        if cancelled { throw CancellationError() }
        try process.run()
    }

    func cancel() {
        lock.lock(); defer { lock.unlock() }
        cancelled = true
        guard process.isRunning else { return }
        process.terminate()
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.5) { [self] in
            lock.lock(); defer { lock.unlock() }
            if process.isRunning { kill(process.processIdentifier, SIGKILL) }
        }
    }
}

/// Runs `whisper-cli` on a WAV file and reads its `.txt` output.
struct LocalWhisperService: Sendable {
    func transcribe(audioURL: URL, executableURL: URL, modelURL: URL, language: String, prompt: String) async throws -> String {
        let output = audioURL.deletingPathExtension().appendingPathExtension("transcript")
        let textURL = output.appendingPathExtension("txt")
        defer { try? FileManager.default.removeItem(at: textURL) }
        let child = WhisperProcess()
        child.process.executableURL = executableURL
        child.process.standardOutput = FileHandle.nullDevice
        child.process.standardError = FileHandle.nullDevice
        child.process.arguments = ["-m", modelURL.path, "-f", audioURL.path, "-l", language, "-otxt", "-of", output.path, "-np"]
            + (prompt.isEmpty ? [] : ["--prompt", prompt])
        let code: Int32 = try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                child.process.terminationHandler = { process in continuation.resume(returning: process.terminationStatus) }
                do { try child.launch() } catch { continuation.resume(throwing: error) }
            }
        } onCancel: { child.cancel() }
        try Task.checkCancellation()
        guard code == 0 else {
            throw DictationError(String(localized: "Local transcription failed. Check the executable and model.", bundle: .module))
        }
        guard let size = try? textURL.resourceValues(forKeys: [.fileSizeKey]).fileSize, size <= 1_048_576,
              let text = try? String(contentsOf: textURL, encoding: .utf8) else {
            throw DictationError(String(localized: "Could not read the local transcription result.", bundle: .module))
        }
        return text
    }
}
