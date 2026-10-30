import Foundation

/// Messages shown under "Error details". They match the Tauri app's wording where one exists.
enum UpdateError: Error, Equatable {
    case busy
    case noPendingUpdate
    case development
    case notInstalledApp
    case network
    case invalidFeed
    case missingPlatform
    case signature
    case archive
    case unsupportedEntry
    case tooLarge
    case identityChanged
    case versionMismatch
    case replaceFailed
    case notInstalled

    var message: String {
        switch self {
        case .busy: String(localized: "An update operation is already running.", bundle: .module)
        case .noPendingUpdate: String(localized: "Check for an update first.", bundle: .module)
        case .development: String(localized: "Development builds cannot install updates.", bundle: .module)
        case .notInstalledApp: String(localized: "Install Prism in Applications before updating.", bundle: .module)
        case .network: String(localized: "Could not reach the update server.", bundle: .module)
        case .invalidFeed: String(localized: "The update information is invalid.", bundle: .module)
        case .missingPlatform: String(localized: "The update is not available for this Mac.", bundle: .module)
        case .signature: String(localized: "The update signature is invalid. The installed app was not changed.", bundle: .module)
        case .archive: String(localized: "Invalid app update archive.", bundle: .module)
        case .unsupportedEntry: String(localized: "The update contains an unsupported app archive entry.", bundle: .module)
        case .tooLarge: String(localized: "The update is too large.", bundle: .module)
        case .identityChanged: String(localized: "This update changes Prism's signing identity and would reset macOS permissions. The installed app was not changed.", bundle: .module)
        case .versionMismatch: String(localized: "The downloaded app is not the announced version. The installed app was not changed.", bundle: .module)
        case .replaceFailed: String(localized: "Could not replace Prism. Check that Prism is in a folder you can write to.", bundle: .module)
        case .notInstalled: String(localized: "No installed update is ready.", bundle: .module)
        }
    }

    init(_ failure: UpdateArchive.Failure) {
        switch failure {
        case .invalidArchive, .writeFailed: self = .archive
        case .unsupportedEntry: self = .unsupportedEntry
        case .tooLarge: self = .tooLarge
        }
    }
}

/// Downloads an update archive into a private temporary directory.
struct UpdateDownloader: Sendable {
    var session: URLSession
    static let maximumDownloadSize: Int64 = 512 * 1024 * 1024

    func download(_ url: URL, into directory: URL) async throws(UpdateError) -> URL {
        var request = URLRequest(url: url, timeoutInterval: 30)
        request.setValue("application/octet-stream", forHTTPHeaderField: "Accept")
        let location: URL
        let response: URLResponse
        do {
            (location, response) = try await session.download(for: request)
        } catch {
            throw .network
        }
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else { throw .network }
        let destination = directory.appending(path: "update.app.tar.gz")
        do {
            let size = try location.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
            guard Int64(size) <= Self.maximumDownloadSize else { throw UpdateError.tooLarge }
            try FileManager.default.moveItem(at: location, to: destination)
        } catch let error as UpdateError {
            throw error
        } catch {
            throw .network
        }
        return destination
    }
}

/// Verifies a downloaded archive and swaps it in for the installed app bundle.
struct UpdateInstaller: Sendable {
    var verifier: any CodeSigningVerifier
    var publicKey: String = Minisign.prismPublicKey
    /// Tells Launch Services about the replaced bundle. Tests leave it out.
    var didReplace: @Sendable (URL) -> Void = { _ in }

    /// Checks the minisign signature, unpacks the archive next to `installed`, checks the new bundle's identity,
    /// version and code signature, then atomically exchanges the two bundles. Nothing is changed on failure.
    func install(archive: URL, signature: String, version: SemanticVersion, over installed: URL) throws(UpdateError) {
        guard installed.pathExtension == "app", FileManager.default.fileExists(atPath: installed.path) else { throw .notInstalledApp }
        do {
            try Minisign.verify(file: archive, signature: signature, publicKey: publicKey)
        } catch {
            throw .signature
        }

        // A replacement directory on the installed app's volume lets the final rename be a single atomic swap.
        let staging: URL
        do {
            staging = try FileManager.default.url(for: .itemReplacementDirectory, in: .userDomainMask, appropriateFor: installed, create: true)
        } catch {
            throw .replaceFailed
        }
        defer { try? FileManager.default.removeItem(at: staging) }

        let candidate: URL
        do {
            candidate = try UpdateArchive.extract(archive, into: staging)
        } catch {
            throw UpdateError(error)
        }
        let next = Self.infoPlist(candidate)
        let current = Self.infoPlist(installed)
        guard let nextIdentifier = next?["CFBundleIdentifier"] as? String,
              nextIdentifier == current?["CFBundleIdentifier"] as? String
        else { throw .identityChanged }
        guard let nextVersion = (next?["CFBundleShortVersionString"] as? String).flatMap(SemanticVersion.init), nextVersion == version else {
            throw .versionMismatch
        }
        do {
            try verifier.verifyCompatible(candidate: candidate, installed: installed)
        } catch {
            throw .identityChanged
        }
        guard renamex_np(candidate.path, installed.path, UInt32(RENAME_SWAP)) == 0 else { throw .replaceFailed }
        // The previous app is now at `candidate` and is removed with the staging directory.
        didReplace(installed)
    }

    /// Read directly: `Bundle` caches by path and would report the replaced app's values.
    static func infoPlist(_ app: URL) -> [String: Any]? {
        NSDictionary(contentsOf: app.appending(path: "Contents/Info.plist")) as? [String: Any]
    }
}
