// Explicit, local-only device verification. No STT call and no permission prompt.
import AppKit
import AVFoundation
import Foundation

@main struct DictationDeviceCheck {
    @MainActor static func main() async throws {
        guard AVCaptureDevice.authorizationStatus(for: .audio) == .authorized else {
            print("SKIP: Microphone permission is not authorized for this verification process."); return
        }
        let recorder = AudioRecorder()
        var samples = 0
        recorder.onLevel = { _ in samples += 1 }
        try await recorder.start()
        try await Task.sleep(for: .seconds(1))
        guard let url = recorder.stop() else { fatalError("Recorder produced no WAV") }
        defer { try? FileManager.default.removeItem(at: url) }
        let audio = try AVAudioFile(forReading: url)
        precondition(audio.length > 0)
        precondition(audio.fileFormat.sampleRate == 16_000 && audio.fileFormat.channelCount == 1)
        let byteCount = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        print("PASS: actual microphone start/stop; WAV 16000 Hz, mono; \(byteCount) bytes, \(samples) level samples. Audio deleted on exit.")
        guard !AXIsProcessTrusted() else {
            print("SKIP: external-app insertion requires a user-selected target; this check does not type into the active app."); return
        }
        // Preserve all existing clipboard representations. Restore only our own test write.
        let board = NSPasteboard.general
        let snapshot = (board.pasteboardItems ?? []).map { item in
            item.types.compactMap { type in item.data(forType: type).map { (type, $0) } }
        }
        let result = await TextInjector.deliver("Prism dictation device check", paste: true, pressEnterAfterPaste: false, target: nil)
        let revision = board.changeCount
        precondition(result == .permissionRequired)
        precondition(board.string(forType: .string) == "Prism dictation device check")
        precondition(board.types?.contains(NSPasteboard.PasteboardType("org.nspasteboard.TransientType")) == true)
        if board.changeCount == revision {
            board.clearContents()
            let items = snapshot.map { entries in let item = NSPasteboardItem(); for (type, data) in entries { item.setData(data, forType: type) }; return item }
            if !items.isEmpty { board.writeObjects(items) }
        }
        print("PASS: denied Accessibility falls back to actual clipboard; previous clipboard restored.")
        print("NOT VERIFIED: external-app text insertion (Accessibility denied in this process). No provider request was made.")
    }
}
