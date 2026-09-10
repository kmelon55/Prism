// Adapted from Whisp. Copyright (c) 2026 Whisp contributors. MIT; see LICENSE-Whisp.
import Foundation

// Serializes launch and cancellation. No pipe that can fill while awaiting exit.
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
        if process.isRunning {
            process.terminate()
            DispatchQueue.global().asyncAfter(deadline: .now() + 0.5) { [self] in
                lock.lock(); defer { lock.unlock() }
                if process.isRunning { kill(process.processIdentifier, SIGKILL) }
            }
        }
    }
}
struct LocalWhisperService {
    func transcribe(audioURL: URL, executableURL: URL, modelURL: URL, language: String, prompt: String) async throws -> String {
        let output = audioURL.deletingPathExtension().appendingPathExtension("transcript")
        let textURL = output.appendingPathExtension("txt")
        defer { try? FileManager.default.removeItem(at: textURL) }
        let child = WhisperProcess()
        child.process.executableURL = executableURL
        child.process.standardOutput = FileHandle.nullDevice
        child.process.standardError = FileHandle.nullDevice
        child.process.arguments = ["-m", modelURL.path, "-f", audioURL.path, "-l", language, "-otxt", "-of", output.path, "-np"] + (prompt.isEmpty ? [] : ["-p", prompt])
        let code: Int32 = try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                child.process.terminationHandler = { process in continuation.resume(returning: process.terminationStatus) }
                do { try child.launch() } catch { continuation.resume(throwing: error) }
            }
        } onCancel: { child.cancel() }
        try Task.checkCancellation()
        guard code == 0 else { throw DictationFailure("로컬 전사에 실패했습니다. 실행 파일과 모델을 확인하세요.") }
        guard let size = try? textURL.resourceValues(forKeys: [.fileSizeKey]).fileSize, size <= 1_048_576,
              let text = try? String(contentsOf: textURL, encoding: .utf8) else { throw DictationFailure("로컬 전사 결과를 읽지 못했습니다.") }
        return text
    }
}
