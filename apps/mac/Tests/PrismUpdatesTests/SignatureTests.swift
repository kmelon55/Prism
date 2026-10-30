import Foundation
import Testing
@testable import PrismUpdates

private func hex(_ data: Data) -> String { data.map { String(format: "%02x", $0) }.joined() }

/// RFC 7693 and Node's `blake2b512` digests.
struct BLAKE2bTests {
    @Test func matchesReferenceDigests() {
        #expect(hex(BLAKE2b512.hash(Data())) == "786a02f742015903c6c6fd852552d272912f4740e15847618a86e217f71f5419d25e1031afee585313896444934eb04b903a685b1448b755d56f701afe9be2ce")
        #expect(hex(BLAKE2b512.hash(Data("abc".utf8))) == "ba80a53f981c4d0d6a2797b69f12f6e94c212f14685ac4b74b12bb6fdbffa2d17d87c5392aab792dc252d5de4533cc9518d38aa8dbf1925ab92386edd4009923")
        #expect(hex(BLAKE2b512.hash(Data(repeating: 0x61, count: 1000))) == "d6a69459fe93fc6b9537ed4336e5099e0dcca3e97290a412500ed7a0daffb03d80cf3650a20e0591f748e10c3c534945ee83d5f2c9722f1a68d98b8c01af23fd")
    }

    @Test(arguments: [1, 7, 127, 128, 129, 256, 300])
    func chunkedInputMatchesOneShot(chunk: Int) {
        let data = Data((0..<1000).map { UInt8(truncatingIfNeeded: $0 &* 31) })
        var hasher = BLAKE2b512()
        var offset = 0
        while offset < data.count {
            hasher.update(data[offset..<min(offset + chunk, data.count)])
            offset += chunk
        }
        #expect(hasher.finalize() == BLAKE2b512.hash(data))
    }
}

/// Ported from `scripts/verify-updater.test.mjs`. The fixture was signed by Node (Ed25519 over Node's BLAKE2b),
/// so it checks this implementation against an independent one.
struct MinisignTests {
    static let nodeKey = "dW50cnVzdGVkIGNvbW1lbnQ6IG1pbmlzaWduIHB1YmxpYyBrZXk6IDA4MDcwNjA1MDQwMzAyMDEKUldRQkFnTUVCUVlIQ09wS2JHUGluRklLdnZWUWV4TXV4Zm1WUjNhdXZyNTdra0llNm1rVVJ0SXMK"
    static let nodeSignature = "dW50cnVzdGVkIGNvbW1lbnQ6IHNpZ25hdHVyZSBmcm9tIHRhdXJpIHNlY3JldCBrZXkKUlVRQkFnTUVCUVlIQ05OSGM1Yy8zQ1RYbFlVNG9uUFNpRVlzY2dsOFdjcEJ3SHNwbDAyOW9GMFpEQTBvb2M3SlhaS1JXTkhTUWliY0d4ZkJaRWNySTZrWDZLTTQ4OEJmTWdNPQp0cnVzdGVkIGNvbW1lbnQ6IHRpbWVzdGFtcDoxMjM0CWZpbGU6UHJpc20uYXBwLnRhci5negphb2Vwa1lQMmY4dS9pNzhRRWpmYmFycjNlU25rdWJsdUVKOTBXc3dUemJYNi9YSXhzdll6SGRybWFQNmFHeTNKREhsZkZIVGVLUSt6cVRjR295VWREUT09Cg=="
    static let payload = Data("synthetic update archive".utf8)

    @Test func verifiesTheArchiveAndTrustedCommentAndRejectsCorruptionAndOtherKeys() throws {
        try Minisign.verify(data: Self.payload, signature: Self.nodeSignature, publicKey: Self.nodeKey)
        #expect(throws: Minisign.Failure.mismatch) {
            try Minisign.verify(data: Data("tampered archive".utf8), signature: Self.nodeSignature, publicKey: Self.nodeKey)
        }
        #expect(throws: Minisign.Failure.mismatch) {
            try Minisign.verify(data: Self.payload, signature: Self.nodeSignature, publicKey: TestSigner().publicKey)
        }
        let decoded = String(decoding: Data(base64Encoded: Self.nodeSignature)!, as: UTF8.self)
        let modified = Data(decoded.replacingOccurrences(of: "timestamp:1234", with: "timestamp:9999").utf8).base64EncodedString()
        #expect(throws: Minisign.Failure.mismatch) {
            try Minisign.verify(data: Self.payload, signature: modified, publicKey: Self.nodeKey)
        }
        #expect(throws: Minisign.Failure.malformed) {
            try Minisign.verify(data: Self.payload, signature: "invalid", publicKey: Self.nodeKey)
        }
        #expect(throws: Minisign.Failure.malformed) {
            try Minisign.verify(data: Self.payload, signature: "", publicKey: Self.nodeKey)
        }
    }

    @Test func rejectsLegacyUnhashedSignatures() {
        let decoded = String(decoding: Data(base64Encoded: Self.nodeSignature)!, as: UTF8.self)
        var lines = decoded.split(separator: "\n").map(String.init)
        var packet = Data(base64Encoded: lines[1])!
        packet[packet.startIndex + 1] = UInt8(ascii: "d")
        lines[1] = packet.base64EncodedString()
        let legacy = Data(lines.joined(separator: "\n").utf8).base64EncodedString()
        #expect(throws: Minisign.Failure.malformed) {
            try Minisign.verify(data: Self.payload, signature: legacy, publicKey: Self.nodeKey)
        }
    }

    @Test func acceptsWindowsLineEndings() throws {
        let decoded = String(decoding: Data(base64Encoded: Self.nodeSignature)!, as: UTF8.self)
        let crlf = Data(decoded.replacingOccurrences(of: "\n", with: "\r\n").utf8).base64EncodedString()
        try Minisign.verify(data: Self.payload, signature: crlf, publicKey: Self.nodeKey)
    }

    @Test func parsesPrismsUpdaterKey() throws {
        let key = try Minisign.publicKey(base64: Minisign.prismPublicKey)
        // minisign prints the little-endian key ID reversed.
        #expect(hex(Data(key.keyID.reversed())).uppercased() == "3494315A359D34A7")
    }

    @Test func verifiesLargeFilesInChunks() throws {
        let directory = TemporaryDirectory()
        let file = directory.url.appending(path: "archive")
        let data = Data((0..<(3 << 20) + 17).map { UInt8(truncatingIfNeeded: $0 &* 13) })
        try data.write(to: file)
        let signer = TestSigner()
        try Minisign.verify(file: file, signature: signer.sign(data), publicKey: signer.publicKey)
        #expect(throws: Minisign.Failure.mismatch) {
            try Minisign.verify(file: file, signature: signer.sign(data + Data([0])), publicKey: signer.publicKey)
        }
    }
}

struct SemanticVersionTests {
    @Test func ordersBySemverPrecedence() {
        let ordered = ["1.0.0-alpha", "1.0.0-alpha.1", "1.0.0-alpha.beta", "1.0.0-beta", "1.0.0-beta.2", "1.0.0-beta.11",
                       "1.0.0-rc.1", "1.0.0", "1.0.1", "1.1.0", "2.0.0", "10.0.0"].map { SemanticVersion($0)! }
        for (lower, higher) in zip(ordered, ordered.dropFirst()) {
            #expect(lower < higher, "\(lower) < \(higher)")
            #expect(!(higher < lower))
        }
        #expect(SemanticVersion("v0.2.0")! == SemanticVersion("0.2.0")!)
        #expect(SemanticVersion("1.0.0+build.5")! == SemanticVersion("1.0.0")!)
        #expect(SemanticVersion("0.1.19")! < SemanticVersion("0.1.20")!)
    }

    @Test(arguments: ["", "1", "1.0", "1.0.0.0", "01.0.0", "1.0.0-01", "1.0.0-", "a.b.c", "1.0.0-alpha..1", "-1.0.0"])
    func rejectsInvalidVersions(text: String) {
        #expect(SemanticVersion(text) == nil)
    }
}

struct UpdateFeedTests {
    /// The shape `scripts/package-release.mjs` writes.
    static func feed(version: String = "0.2.0", url: String = "https://github.com/kmelon55/Prism/releases/download/v0.2.0/Prism_0.2.0_universal.app.tar.gz", platforms: [String] = ["darwin-aarch64", "darwin-x86_64"]) -> Data {
        let entries = platforms.map { "\"\($0)\": {\"signature\": \"c2ln\", \"url\": \"\(url)\"}" }.joined(separator: ",")
        return Data("""
        {"version": "\(version)", "notes": "Prism \(version).", "pub_date": "2026-10-29T00:00:00.000Z", "platforms": {\(entries)}}
        """.utf8)
    }

    @Test func findsANewerReleaseForThisMac() throws {
        let current = SemanticVersion("0.1.19")!
        for target in ["darwin-aarch64", "darwin-x86_64"] {
            let release = try #require(try UpdateFeed.update(in: Self.feed(), currentVersion: current, target: target))
            #expect(release.version.description == "0.2.0")
            #expect(release.url.lastPathComponent == "Prism_0.2.0_universal.app.tar.gz")
            #expect(release.signature == "c2ln")
        }
        #expect(try UpdateFeed.update(in: Self.feed(version: "0.1.19"), currentVersion: current) == nil)
        #expect(try UpdateFeed.update(in: Self.feed(version: "0.1.18"), currentVersion: current) == nil)
        #expect(try UpdateFeed.update(in: Self.feed(version: "v0.2.0"), currentVersion: current) != nil)
    }

    @Test func prefersTheAppInstallerKeyLikeTauri() throws {
        let data = Data("""
        {"version": "0.2.0", "platforms": {
          "darwin-aarch64": {"signature": "b2xk", "url": "https://example.com/old.tar.gz"},
          "darwin-aarch64-app": {"signature": "bmV3", "url": "https://example.com/new.tar.gz"}}}
        """.utf8)
        let release = try UpdateFeed.release(from: data, target: "darwin-aarch64")
        #expect(release.signature == "bmV3")
    }

    @Test func acceptsTheSinglePlatformForm() throws {
        let data = Data(#"{"version": "0.2.0", "url": "https://example.com/a.tar.gz", "signature": "c2ln"}"#.utf8)
        #expect(try UpdateFeed.release(from: data).url.host() == "example.com")
    }

    @Test func rejectsInsecureOrIncompleteFeeds() throws {
        let current = SemanticVersion("0.1.0")!
        #expect(throws: UpdateFeed.Failure.invalidFeed) {
            try UpdateFeed.update(in: Self.feed(url: "http://example.com/a.tar.gz"), currentVersion: current)
        }
        #expect(throws: UpdateFeed.Failure.missingPlatform("darwin-aarch64")) {
            try UpdateFeed.update(in: Self.feed(platforms: ["windows-x86_64"]), currentVersion: current, target: "darwin-aarch64")
        }
        // A feed that is not newer does not need this Mac's platform.
        #expect(try UpdateFeed.update(in: Self.feed(version: "0.1.0", platforms: []), currentVersion: current) == nil)
        for invalid in ["", "{", "{}", #"{"version": "latest"}"#, #"{"version": "0.2.0"}"#] {
            #expect(throws: UpdateFeed.Failure.invalidFeed) {
                try UpdateFeed.update(in: Data(invalid.utf8), currentVersion: current)
            }
        }
    }
}
