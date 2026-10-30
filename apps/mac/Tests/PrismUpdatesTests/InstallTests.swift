import Foundation
import Testing
@testable import PrismUpdates

/// Ported from `update_signature.rs` (`rejects_archive_links_and_unexpected_roots`) plus the gzip and tar
/// formats the release tools write. Everything happens in temporary directories.
struct UpdateArchiveTests {
    private func extract(_ archive: Data) throws(UpdateArchive.Failure) -> (TemporaryDirectory, URL) {
        let directory = TemporaryDirectory()
        let file = directory.url.appending(path: "update.tar.gz")
        try! archive.write(to: file)
        let output = directory.url.appending(path: "out", directoryHint: .isDirectory)
        try! FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        return (directory, try UpdateArchive.extract(file, into: output))
    }

    @Test func extractsAnAppWithExecutablePermissions() throws {
        let (directory, app) = try extract(makeUpdateArchive(version: "0.2.0"))
        _ = directory
        let executable = app.appending(path: "Contents/MacOS/Prism")
        #expect(try String(contentsOf: executable, encoding: .utf8) == "new 0.2.0")
        let permissions = try FileManager.default.attributesOfItem(atPath: executable.path)[.posixPermissions] as? Int
        #expect(permissions == 0o755)
        #expect(UpdateInstaller.infoPlist(app)?["CFBundleShortVersionString"] as? String == "0.2.0")
        // The intermediate tar file is removed.
        #expect(try FileManager.default.contentsOfDirectory(atPath: app.deletingLastPathComponent().path) == ["Prism.app"])
    }

    @Test func readsGNULongNamesAndPaxPaths() throws {
        let long = "Prism.app/Contents/Resources/" + String(repeating: "deep/", count: 20) + "file.txt"
        var tar = TarBuilder()
        tar.longFile(long, Data("long".utf8))
        tar.paxFile("Prism.app/Contents/Resources/pax.txt", Data("pax".utf8))
        let (directory, app) = try extract(tar.gzipped())
        _ = directory
        let root = app.deletingLastPathComponent()
        #expect(try String(contentsOf: root.appending(path: long), encoding: .utf8) == "long")
        #expect(try String(contentsOf: root.appending(path: "Prism.app/Contents/Resources/pax.txt"), encoding: .utf8) == "pax")
        #expect(!FileManager.default.fileExists(atPath: root.appending(path: "ignored-name").path))
    }

    @Test func readsArchivesMadeByMacOSTar() throws {
        let directory = TemporaryDirectory()
        let source = makeInstalledApp(in: directory.url, version: "0.3.0")
        let archive = directory.url.appending(path: "bsd.tar.gz")
        let tar = Process()
        tar.executableURL = URL(filePath: "/usr/bin/tar")
        tar.currentDirectoryURL = directory.url
        tar.environment = ["COPYFILE_DISABLE": "1"]
        tar.arguments = ["--no-mac-metadata", "--no-xattrs", "-czf", archive.path, source.lastPathComponent]
        try tar.run()
        tar.waitUntilExit()
        #expect(tar.terminationStatus == 0)
        let (output, app) = try extract(try Data(contentsOf: archive))
        _ = output
        #expect(UpdateInstaller.infoPlist(app)?["CFBundleShortVersionString"] as? String == "0.3.0")
    }

    @Test func rejectsLinksUnexpectedRootsAndEscapingPaths() {
        let cases: [(String, (inout TarBuilder) -> Void)] = [
            ("other root", { $0.file("Other.app/file") }),
            ("symlink", { $0.directory("Prism.app/"); $0.symlink("Prism.app/link", to: "/tmp") }),
            ("hard link", { $0.entry("Prism.app/hard", type: "1", size: 0, mode: 0o644, link: "Prism.app/a") }),
            ("parent", { $0.file("Prism.app/../escape") }),
            ("absolute", { $0.file("/Prism.app/file") }),
            ("dot root", { $0.file("./Prism.app/file") }),
            ("fifo", { $0.entry("Prism.app/fifo", type: "6", size: 0, mode: 0o644) }),
            ("global pax", { $0.entry("pax_global_header", type: "g", size: 0, mode: 0o644) }),
        ]
        for (name, build) in cases {
            var tar = TarBuilder()
            build(&tar)
            #expect(throws: UpdateArchive.Failure.self, "\(name)") { try extract(tar.gzipped()) }
        }
    }

    @Test func rejectsOversizedEntriesBeforeReadingThem() {
        var tar = TarBuilder()
        tar.entry("Prism.app/huge", type: "0", size: Int(UpdateArchive.maximumSize) + 1, mode: 0o644)
        #expect(throws: UpdateArchive.Failure.tooLarge) { try extract(tar.gzipped()) }
    }

    @Test func rejectsCorruptGzip() {
        var archive = makeUpdateArchive(version: "0.2.0")
        archive[archive.count - 6] ^= 0xFF
        #expect(throws: UpdateArchive.Failure.invalidArchive) { try extract(archive) }
        #expect(throws: UpdateArchive.Failure.invalidArchive) { try extract(archive.prefix(archive.count / 2)) }
        #expect(throws: UpdateArchive.Failure.invalidArchive) { try extract(Data("not gzip".utf8)) }
        #expect(throws: UpdateArchive.Failure.invalidArchive) { try extract(gzip(Data("not a tar archive".utf8))) }
    }
}

/// The install step against fake bundles in temporary directories. The real /Applications app is never touched.
struct UpdateInstallerTests {
    let signer = TestSigner()

    private func install(
        archive: Data, signature: String? = nil, version: String = "0.2.0", verifier: FakeVerifier = FakeVerifier(),
        installedIdentifier: String = "dev.prism.desktop"
    ) throws(UpdateError) -> (TemporaryDirectory, URL) {
        let directory = TemporaryDirectory()
        let app = makeInstalledApp(in: directory.url, identifier: installedIdentifier)
        let file = directory.url.appending(path: "download.tar.gz")
        try! archive.write(to: file)
        let installer = UpdateInstaller(verifier: verifier, publicKey: signer.publicKey)
        try installer.install(archive: file, signature: signature ?? signer.sign(archive), version: SemanticVersion(version)!, over: app)
        return (directory, app)
    }

    private func installedVersion(_ app: URL) -> String? {
        UpdateInstaller.infoPlist(app)?["CFBundleShortVersionString"] as? String
    }

    @Test func replacesTheBundleAndLeavesNothingBehind() throws {
        let (directory, app) = try install(archive: makeUpdateArchive(version: "0.2.0"))
        #expect(installedVersion(app) == "0.2.0")
        #expect(try String(contentsOf: app.appending(path: "Contents/MacOS/Prism"), encoding: .utf8) == "new 0.2.0")
        #expect(try FileManager.default.contentsOfDirectory(atPath: directory.url.path).sorted() == ["Prism.app", "download.tar.gz"])
    }

    @Test func leavesTheInstalledAppUnchangedOnEveryFailure() {
        let good = makeUpdateArchive(version: "0.2.0")
        // Untyped closures: typed-throws function values need the macOS 15 runtime.
        let cases: [(UpdateError, () throws -> (TemporaryDirectory, URL))] = [
            (.signature, { try install(archive: good, signature: TestSigner().sign(good)) }),
            (.signature, { try install(archive: good, signature: signer.sign(makeUpdateArchive(version: "0.3.0"))) }),
            (.signature, { try install(archive: good, signature: "") }),
            (.identityChanged, { try install(archive: good, verifier: FakeVerifier(accepts: false)) }),
            (.identityChanged, { try install(archive: makeUpdateArchive(version: "0.2.0", identifier: "dev.prism.other")) }),
            (.versionMismatch, { try install(archive: makeUpdateArchive(version: "0.1.5")) }),
            (.unsupportedEntry, {
                var tar = TarBuilder()
                tar.symlink("Prism.app", to: "/Applications/Prism.app")
                return try install(archive: tar.gzipped())
            }),
        ]
        for (expected, run) in cases {
            do {
                _ = try run()
                Issue.record("expected \(expected)")
            } catch {
                #expect(error as? UpdateError == expected)
            }
        }
    }

    @Test func failuresDoNotChangeTheBundle() throws {
        let directory = TemporaryDirectory()
        let app = makeInstalledApp(in: directory.url)
        let archive = makeUpdateArchive(version: "0.2.0")
        let file = directory.url.appending(path: "download.tar.gz")
        try archive.write(to: file)
        let installer = UpdateInstaller(verifier: FakeVerifier(accepts: false), publicKey: signer.publicKey)
        #expect(throws: UpdateError.identityChanged) {
            try installer.install(archive: file, signature: signer.sign(archive), version: SemanticVersion("0.2.0")!, over: app)
        }
        #expect(installedVersion(app) == "0.1.0")
        #expect(try String(contentsOf: app.appending(path: "Contents/MacOS/Prism"), encoding: .utf8) == "old")
    }

    @Test func requiresAnInstalledAppBundle() throws {
        let directory = TemporaryDirectory()
        let installer = UpdateInstaller(verifier: FakeVerifier(), publicKey: signer.publicKey)
        #expect(throws: UpdateError.notInstalledApp) {
            try installer.install(archive: directory.url, signature: "", version: SemanticVersion("0.2.0")!, over: directory.url.appending(path: "Prism"))
        }
    }
}

/// Ported from `requires_a_certificate_identity_for_the_same_app` in `update_signature.rs`.
struct CodeSigningTests {
    static let identity = CodeSigningIdentity(
        identifier: "dev.prism.desktop", isAdHoc: false, hasCertificate: true,
        designatedRequirement: #"identifier "dev.prism.desktop" and certificate leaf = H"012345""#
    )

    @Test func requiresACertificateIdentityForTheSameApp() throws {
        #expect(try CodeSigning.requirement(of: Self.identity, expectedIdentifier: "dev.prism.desktop") == Self.identity.designatedRequirement)
        var adHoc = Self.identity
        adHoc.isAdHoc = true
        var noCertificate = Self.identity
        noCertificate.hasCertificate = false
        var cdhash = Self.identity
        cdhash.designatedRequirement = #"cdhash H"012345""#
        var other = Self.identity
        other.identifier = "dev.prism.desktop.test"
        other.designatedRequirement = #"identifier "dev.prism.desktop.test" and certificate leaf = H"012345""#
        var missing = Self.identity
        missing.designatedRequirement = nil
        for identity in [adHoc, noCertificate, cdhash, other, missing] {
            #expect(throws: CodeSigningFailure.identityChanged) {
                try CodeSigning.requirement(of: identity, expectedIdentifier: "dev.prism.desktop")
            }
        }
    }

    /// A real ad-hoc signature, made in a temporary directory, is never accepted.
    @Test func rejectsAnAdHocSignedBundle() throws {
        let directory = TemporaryDirectory()
        let app = makeInstalledApp(in: directory.url)
        let executable = app.appending(path: "Contents/MacOS/Prism")
        try FileManager.default.removeItem(at: executable)
        try FileManager.default.copyItem(at: URL(filePath: "/usr/bin/true"), to: executable)
        let codesign = Process()
        codesign.executableURL = URL(filePath: "/usr/bin/codesign")
        codesign.arguments = ["--force", "--sign", "-", "--identifier", "dev.prism.desktop", app.path]
        codesign.standardError = FileHandle.nullDevice
        try codesign.run()
        codesign.waitUntilExit()
        try #require(codesign.terminationStatus == 0)

        let identity = try SecurityCodeSigningVerifier.identity(SecurityCodeSigningVerifier.staticCode(app))
        #expect(identity.identifier == "dev.prism.desktop")
        #expect(identity.isAdHoc)
        #expect(!identity.hasCertificate)
        #expect(throws: CodeSigningFailure.identityChanged) {
            try SecurityCodeSigningVerifier(expectedIdentifier: "dev.prism.desktop").verifyCompatible(candidate: app, installed: app)
        }
    }

    @Test func rejectsUnsignedBundles() {
        let directory = TemporaryDirectory()
        let app = makeInstalledApp(in: directory.url)
        #expect(throws: CodeSigningFailure.identityChanged) {
            try SecurityCodeSigningVerifier(expectedIdentifier: "dev.prism.desktop").verifyCompatible(candidate: app, installed: app)
        }
    }

    /// Opt-in, like the ignored Rust test: `PRISM_SIGNED_TEST_APP=/path/to/certificate-signed/Prism.app`.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["PRISM_SIGNED_TEST_APP"] != nil))
    func acceptsARealCertificateSignedApp() throws {
        let app = URL(filePath: ProcessInfo.processInfo.environment["PRISM_SIGNED_TEST_APP"]!)
        try SecurityCodeSigningVerifier(expectedIdentifier: "dev.prism.desktop").verifyCompatible(candidate: app, installed: app)
    }
}

/// Opt-in check against a published release, never run by default:
/// `PRISM_UPDATE_ARCHIVE=…/Prism_x_universal.app.tar.gz PRISM_UPDATE_SIGNATURE=…/signature-from-latest.json`.
struct PublishedReleaseTests {
    static let environment = ProcessInfo.processInfo.environment

    @Test(.enabled(if: environment["PRISM_UPDATE_ARCHIVE"] != nil && environment["PRISM_UPDATE_SIGNATURE"] != nil))
    func verifiesAndUnpacksAPublishedArchive() throws {
        let archive = URL(filePath: Self.environment["PRISM_UPDATE_ARCHIVE"]!)
        let signature = try String(contentsOf: URL(filePath: Self.environment["PRISM_UPDATE_SIGNATURE"]!), encoding: .utf8)
        try Minisign.verify(file: archive, signature: signature, publicKey: Minisign.prismPublicKey)
        let directory = TemporaryDirectory()
        let app = try UpdateArchive.extract(archive, into: directory.url)
        let info = try #require(UpdateInstaller.infoPlist(app))
        #expect(info["CFBundleIdentifier"] as? String == "dev.prism.desktop")
        print("Published archive:", info["CFBundleShortVersionString"] ?? "?")
        // The extracted bundle keeps a valid certificate signature with the release identity.
        let identity = try SecurityCodeSigningVerifier.identity(SecurityCodeSigningVerifier.staticCode(app))
        #expect(!identity.isAdHoc && identity.hasCertificate)
        _ = try CodeSigning.requirement(of: identity, expectedIdentifier: "dev.prism.desktop")
        print("Designated requirement:", identity.designatedRequirement ?? "-")
    }
}
