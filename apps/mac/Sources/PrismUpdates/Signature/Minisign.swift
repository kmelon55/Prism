import CryptoKit
import Foundation

/// Minisign verification in the form the Tauri updater uses: the public key and the `.sig` file are each
/// minisign text wrapped in base64. Ported from `scripts/verify-updater.mjs`.
///
/// Only prehashed "ED" signatures are accepted (Ed25519 over the BLAKE2b-512 of the file), which is what the
/// release pipeline produces; legacy "Ed" signatures over raw bytes are rejected. The trusted comment is
/// verified too, so a signature cannot be paired with a different comment.
enum Minisign {
    struct PublicKey: Equatable {
        let keyID: Data
        let key: Curve25519.Signing.PublicKey

        static func == (lhs: PublicKey, rhs: PublicKey) -> Bool {
            lhs.keyID == rhs.keyID && lhs.key.rawRepresentation == rhs.key.rawRepresentation
        }
    }

    struct Signature {
        let keyID: Data
        let signature: Data
        let trustedComment: String
        let globalSignature: Data
    }

    enum Failure: Error, Equatable {
        case malformed
        case mismatch
    }

    /// The updater public key from `tauri.conf.json` (`plugins.updater.pubkey`).
    static let prismPublicKey = "dW50cnVzdGVkIGNvbW1lbnQ6IG1pbmlzaWduIHB1YmxpYyBrZXk6IDM0OTQzMTVBMzU5RDM0QTcKUldTbk5KMDFXakdVTkZKSGlUT0JjcnJ6MloxcDFVL1NKYkhGSlFYaTlJRm5Dbk9ESTNxUktoREwK"

    static func publicKey(base64 encoded: String) throws(Failure) -> PublicKey {
        let lines = try wrappedLines(encoded)
        guard lines.count >= 2, let raw = Data(base64Encoded: lines[1]), raw.count == 42,
              raw.prefix(2) == Data("Ed".utf8),
              let key = try? Curve25519.Signing.PublicKey(rawRepresentation: raw.suffix(32))
        else { throw .malformed }
        return PublicKey(keyID: Data(raw[raw.startIndex + 2..<raw.startIndex + 10]), key: key)
    }

    static func signature(base64 encoded: String) throws(Failure) -> Signature {
        let lines = try wrappedLines(encoded)
        let prefix = "trusted comment: "
        guard lines.count >= 4, let packet = Data(base64Encoded: lines[1]), packet.count == 74,
              packet.prefix(2) == Data("ED".utf8), lines[2].hasPrefix(prefix),
              let global = Data(base64Encoded: lines[3]), global.count == 64
        else { throw .malformed }
        let start = packet.startIndex
        return Signature(
            keyID: Data(packet[start + 2..<start + 10]),
            signature: Data(packet[start + 10..<start + 74]),
            trustedComment: String(lines[2].dropFirst(prefix.count)),
            globalSignature: global
        )
    }

    /// Verifies a BLAKE2b-512 digest of the signed file against the signature and its trusted comment.
    static func verify(digest: Data, signature: Signature, publicKey: PublicKey) throws(Failure) {
        guard signature.keyID == publicKey.keyID else { throw .mismatch }
        guard publicKey.key.isValidSignature(signature.signature, for: digest),
              publicKey.key.isValidSignature(signature.globalSignature, for: signature.signature + Data(signature.trustedComment.utf8))
        else { throw .mismatch }
    }

    static func verify(data: Data, signature encodedSignature: String, publicKey encodedKey: String) throws(Failure) {
        try verify(digest: BLAKE2b512.hash(data), signature: signature(base64: encodedSignature), publicKey: publicKey(base64: encodedKey))
    }

    /// Hashes a file in chunks and verifies it, so large archives never load into memory at once.
    static func verify(file: URL, signature encodedSignature: String, publicKey encodedKey: String) throws(Failure) {
        let signature = try signature(base64: encodedSignature)
        let key = try publicKey(base64: encodedKey)
        guard let handle = try? FileHandle(forReadingFrom: file) else { throw .mismatch }
        defer { try? handle.close() }
        var hasher = BLAKE2b512()
        while true {
            // `read` returns nil at the end of the file.
            let chunk: Data?
            do { chunk = try handle.read(upToCount: 1 << 20) } catch { throw .mismatch }
            guard let chunk, !chunk.isEmpty else { break }
            hasher.update(chunk)
        }
        try verify(digest: hasher.finalize(), signature: signature, publicKey: key)
    }

    private static func wrappedLines(_ encoded: String) throws(Failure) -> [String] {
        guard let data = Data(base64Encoded: encoded.trimmingCharacters(in: .whitespacesAndNewlines)),
              let text = String(data: data, encoding: .utf8)
        else { throw .malformed }
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
            // "\r\n" is a single Character, so this also splits Windows line endings.
            .split(omittingEmptySubsequences: false, whereSeparator: \.isNewline)
            .map(String.init)
    }
}
