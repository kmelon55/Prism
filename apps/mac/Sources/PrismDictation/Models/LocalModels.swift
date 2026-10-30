import CryptoKit
import Foundation
import Observation
import PrismKit

/// A curated whisper.cpp model, pinned to one repository revision and checksum.
struct LocalModel: Identifiable, Equatable, Sendable {
    let id: String
    let name: String
    let description: String
    let bytes: Int64
    let sha256: String

    var fileName: String { "ggml-\(id).bin" }

    var localizedDescription: String {
        switch id {
        case "large-v3-turbo-q5_0": String(localized: "Smaller download with 5-bit quantization. Supports Korean and multilingual dictation.", bundle: .module)
        case "large-v3-turbo": String(localized: "Fewer decoder layers than Large v3 for faster transcription. Supports Korean.", bundle: .module)
        case "large-v3": String(localized: "Full-size multilingual model. Needs more memory and processing time. Supports Korean.", bundle: .module)
        case "small": String(localized: "A smaller multilingual model for Macs with limited memory. Supports Korean.", bundle: .module)
        case "medium": String(localized: "A multilingual model between Small and Large in size. Supports Korean.", bundle: .module)
        default: description
        }
    }

    static let revision = "5359861c739e955e79d9a303bcbc70fb988958b1"

    static let all: [LocalModel] = [
        LocalModel(id: "large-v3-turbo-q5_0", name: "Whisper Large v3 Turbo · Q5",
                   description: "Smaller download with 5-bit quantization. Supports Korean and multilingual dictation.",
                   bytes: 574_041_195, sha256: "394221709cd5ad1f40c46e6031ca61bce88931e6e088c188294c6d5a55ffa7e2"),
        LocalModel(id: "large-v3-turbo", name: "Whisper Large v3 Turbo",
                   description: "Fewer decoder layers than Large v3 for faster transcription. Supports Korean.",
                   bytes: 1_624_555_275, sha256: "1fc70f774d38eb169993ac391eea357ef47c88757ef72ee5943879b7e8e2bc69"),
        LocalModel(id: "large-v3", name: "Whisper Large v3",
                   description: "Full-size multilingual model. Needs more memory and processing time. Supports Korean.",
                   bytes: 3_095_033_483, sha256: "64d182b440b98d5203c4f9bd541544d84c605196c4f7b845dfa11fb23594d1e2"),
        LocalModel(id: "small", name: "Whisper Small",
                   description: "A smaller multilingual model for Macs with limited memory. Supports Korean.",
                   bytes: 487_601_967, sha256: "1be3a9b2063867b937e64e2ec7483364a79917e157fa98c5d94b5c1fffea987b"),
        LocalModel(id: "medium", name: "Whisper Medium",
                   description: "A multilingual model between Small and Large in size. Supports Korean.",
                   bytes: 1_533_763_059, sha256: "6c14d5adee5f86394037b4e4e8b59f1673b6cee10e3cf0b11bbdbee79c156208"),
    ]

    static func find(_ id: String) -> LocalModel? { all.first { $0.id == id } }

    var downloadURL: URL {
        URL(string: "https://huggingface.co/ggerganov/whisper.cpp/resolve/\(Self.revision)/\(fileName)")!
    }

    static func sizeText(_ bytes: Int64) -> String {
        bytes >= 1_000_000_000 ? String(format: "%.2f GB", Double(bytes) / 1e9) : "\(Int((Double(bytes) / 1e6).rounded())) MB"
    }
}

enum LocalModelFiles {
    static let folderName = "dictation-models"

    /// True only for a regular file of the exact expected size; partial or replaced files are not selectable.
    static func isComplete(_ url: URL, model: LocalModel) -> Bool {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
              attributes[.type] as? FileAttributeType == .typeRegular else { return false }
        return (attributes[.size] as? NSNumber)?.int64Value == model.bytes
    }

    static func verify(bytes: Int64, digest: SHA256.Digest, model: LocalModel) throws {
        let hex = digest.map { String(format: "%02x", $0) }.joined()
        guard bytes == model.bytes, hex == model.sha256 else {
            throw DictationError(String(localized: "The model download is incomplete or damaged. Please retry.", bundle: .module))
        }
    }

    static func verifyExisting(_ url: URL, model: LocalModel) throws {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hash = SHA256()
        var total: Int64 = 0
        while let chunk = try handle.read(upToCount: 1 << 20), !chunk.isEmpty {
            total += Int64(chunk.count)
            hash.update(data: chunk)
        }
        try verify(bytes: total, digest: hash.finalize(), model: model)
    }

    static func executable(_ path: String) -> Bool {
        var isDirectory: ObjCBool = false
        return path.hasPrefix("/") && FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory) && !isDirectory.boolValue
            && FileManager.default.isExecutableFile(atPath: path)
    }

    static func whisperPath(preferred: String) -> String? {
        [preferred, "/opt/homebrew/bin/whisper-cli", "/usr/local/bin/whisper-cli",
         "/opt/homebrew/opt/whisper.cpp/bin/whisper-cli", "/usr/local/opt/whisper.cpp/bin/whisper-cli"].first(where: executable)
    }

    static var brewPath: String? {
        ["/opt/homebrew/bin/brew", "/usr/local/bin/brew"].first(where: executable)
    }
}

/// Streams a model into `<id>.bin.part`, hashing as it goes, and renames it only after length and checksum match.
private final class ModelDownload: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private let model: LocalModel
    private let partial: URL
    private let target: URL
    private let progress: @Sendable (Int64) -> Void
    private let lock = NSLock()
    private var handle: FileHandle?
    private var digest = SHA256()
    private var received: Int64 = 0
    private var lastReport = Date.distantPast
    private var failure: Error?
    private var continuation: CheckedContinuation<URL, Error>?
    private var session: URLSession?

    init(model: LocalModel, directory: URL, progress: @escaping @Sendable (Int64) -> Void) {
        self.model = model
        partial = directory.appending(path: model.fileName + ".part")
        target = directory.appending(path: model.fileName)
        self.progress = progress
    }

    func run() async throws -> URL {
        try FileManager.default.createDirectory(at: partial.deletingLastPathComponent(), withIntermediateDirectories: true)
        // A crashed earlier download leaves a stale partial file; replace it.
        try? FileManager.default.removeItem(at: partial)
        guard FileManager.default.createFile(atPath: partial.path, contents: nil) else {
            throw DictationError(String(localized: "Could not create the model file.", bundle: .module))
        }
        handle = try FileHandle(forWritingTo: partial)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 60
        configuration.timeoutIntervalForResource = 7200
        configuration.urlCache = nil
        let session = URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
        self.session = session
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                lock.lock()
                self.continuation = continuation
                lock.unlock()
                session.dataTask(with: model.downloadURL).resume()
            }
        } onCancel: {
            session.invalidateAndCancel()
        }
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                    completionHandler: @escaping @Sendable (URLSession.ResponseDisposition) -> Void) {
        let http = response as? HTTPURLResponse
        let ok = http.map { (200..<300).contains($0.statusCode) } ?? false
        let lengthMatches = response.expectedContentLength < 0 || response.expectedContentLength == model.bytes
        if !ok || !lengthMatches {
            lock.lock()
            failure = DictationError(ok ? String(localized: "The model download is incomplete or damaged. Please retry.", bundle: .module)
                                         : String(localized: "Could not download the model (\(http?.statusCode ?? 0)).", bundle: .module))
            lock.unlock()
            completionHandler(.cancel)
            return
        }
        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        lock.lock()
        defer { lock.unlock() }
        guard failure == nil else { return }
        received += Int64(data.count)
        guard received <= model.bytes else {
            failure = DictationError(String(localized: "The model download is incomplete or damaged. Please retry.", bundle: .module))
            dataTask.cancel()
            return
        }
        do { try handle?.write(contentsOf: data) } catch {
            failure = error
            dataTask.cancel()
            return
        }
        digest.update(data: data)
        if Date().timeIntervalSince(lastReport) >= 0.15 || received == model.bytes {
            lastReport = Date()
            progress(received)
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        lock.lock()
        let continuation = continuation
        self.continuation = nil
        var outcome: Result<URL, Error>
        if let failure {
            outcome = .failure(failure)
        } else if let error {
            outcome = .failure((error as? URLError)?.code == .cancelled
                ? DictationError(String(localized: "Model download cancelled.", bundle: .module)) : error)
        } else {
            do {
                try LocalModelFiles.verify(bytes: received, digest: digest.finalize(), model: model)
                try handle?.synchronize()
                outcome = .success(target)
            } catch { outcome = .failure(error) }
        }
        try? handle?.close()
        handle = nil
        lock.unlock()
        session.finishTasksAndInvalidate()
        switch outcome {
        case .success:
            do {
                try? FileManager.default.removeItem(at: target)
                try FileManager.default.moveItem(at: partial, to: target)
                continuation?.resume(returning: target)
            } catch {
                try? FileManager.default.removeItem(at: partial)
                continuation?.resume(throwing: error)
            }
        case .failure(let error):
            try? FileManager.default.removeItem(at: partial)
            continuation?.resume(throwing: error)
        }
    }
}

/// Local model catalog with download progress and speech engine detection. Downloads keep running when the
/// picker closes; reopening it shows their progress.
@MainActor
@Observable
final class LocalModelManager {
    struct Download: Equatable {
        let modelID: String
        var downloaded: Int64
        let total: Int64
    }

    private(set) var installed: [String: String] = [:]
    private(set) var whisperPath: String?
    private(set) var canInstallEngine = false
    private(set) var installingEngine = false
    private(set) var download: Download?
    private(set) var verifying: String?

    let directory: URL
    @ObservationIgnored private var downloadTask: Task<URL, Error>?

    init(paths: AppPaths) {
        directory = paths.dataDirectory.appending(path: LocalModelFiles.folderName, directoryHint: .isDirectory)
    }

    func refresh(preferredWhisperPath: String) {
        var installed: [String: String] = [:]
        for model in LocalModel.all {
            let url = directory.appending(path: model.fileName)
            if LocalModelFiles.isComplete(url, model: model) { installed[model.id] = url.path }
        }
        self.installed = installed
        whisperPath = LocalModelFiles.whisperPath(preferred: preferredWhisperPath)
        canInstallEngine = LocalModelFiles.brewPath != nil
    }

    /// Verifies an existing file or downloads the model. Returns the model path.
    func prepare(_ model: LocalModel) async throws -> String {
        guard download == nil, verifying == nil else {
            throw DictationError(String(localized: "Another local model is downloading. Wait or cancel it first.", bundle: .module))
        }
        let target = directory.appending(path: model.fileName)
        if LocalModelFiles.isComplete(target, model: model) {
            verifying = model.id
            defer { verifying = nil }
            let valid = await Task.detached(priority: .userInitiated) { (try? LocalModelFiles.verifyExisting(target, model: model)) != nil }.value
            if valid { return target.path }
        }
        download = Download(modelID: model.id, downloaded: 0, total: model.bytes)
        defer {
            download = nil
            downloadTask = nil
        }
        let directory = directory
        let report: @Sendable (Int64) -> Void = { [weak self] received in
            Task { @MainActor in self?.reportProgress(received, for: model.id) }
        }
        let task = Task<URL, Error> {
            try await ModelDownload(model: model, directory: directory, progress: report).run()
        }
        downloadTask = task
        let url = try await task.value
        refresh(preferredWhisperPath: whisperPath ?? "")
        return url.path
    }

    private func reportProgress(_ received: Int64, for modelID: String) {
        if download?.modelID == modelID { download?.downloaded = received }
    }

    func cancelDownload() {
        downloadTask?.cancel()
    }

    /// Runs `brew install whisper.cpp` only when the user asks. Output goes to `engine-install.log`.
    func installEngine() async throws -> String {
        if let path = LocalModelFiles.whisperPath(preferred: "") { return path }
        guard let brew = LocalModelFiles.brewPath else {
            throw DictationError(String(localized: "Install Homebrew or choose an existing whisper-cli in Advanced settings.", bundle: .module))
        }
        guard !installingEngine else { throw DictationError(String(localized: "Speech engine installation is already running.", bundle: .module)) }
        installingEngine = true
        defer { installingEngine = false }
        let directory = directory
        let status = try await Task.detached(priority: .userInitiated) { () throws -> Int32 in
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let logURL = directory.appending(path: "engine-install.log")
            FileManager.default.createFile(atPath: logURL.path, contents: nil)
            let log = try FileHandle(forWritingTo: logURL)
            defer { try? log.close() }
            let process = Process()
            process.executableURL = URL(filePath: brew)
            process.arguments = ["install", "whisper.cpp"]
            var environment = ProcessInfo.processInfo.environment
            environment["NONINTERACTIVE"] = "1"
            environment["HOMEBREW_NO_AUTO_UPDATE"] = "1"
            environment["HOMEBREW_NO_INSTALL_CLEANUP"] = "1"
            process.environment = environment
            process.standardInput = FileHandle.nullDevice
            process.standardOutput = log
            process.standardError = log
            try process.run()
            process.waitUntilExit()
            return process.terminationStatus
        }.value
        guard status == 0 else {
            throw DictationError(String(localized: "Speech engine installation failed. Run brew install whisper.cpp in Terminal, then check again.", bundle: .module))
        }
        guard let path = LocalModelFiles.whisperPath(preferred: "") else {
            throw DictationError(String(localized: "The speech engine was not found. Choose whisper-cli in Advanced settings.", bundle: .module))
        }
        whisperPath = path
        return path
    }
}
