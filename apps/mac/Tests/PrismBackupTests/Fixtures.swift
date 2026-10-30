import CommonCrypto
import Compression
import CryptoKit
import Foundation
import PrismKit
@testable import PrismBackup

/// Synthetic fixtures only. No user export or library data.
enum Fixtures {
    static func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appending(path: "prism-backup-test-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    static func library() throws -> BackupLibrary {
        try BackupLibrary(database: .inMemory())
    }

    static func document() -> BackupDocument {
        BackupDocument(version: 1, entries: [BackupEntry(id: "one", kind: "snippet", title: "Example", value: "Hello")],
                       favorites: [BackupFavorite(id: "library:one", title: "Example")], preferences: nil)
    }

    static let categories = BackupCategories(snippets: true, notes: true, quicklinks: true, pathLinks: false, favorites: true, preferences: false)

    static func preferences(aliases: [String: String] = ["prism:settings": "settings"]) -> SafePreferences {
        SafePreferences(language: "en", theme: "dark", reduceMotion: false, backgroundOpacity: 97, backgroundBlur: 44,
                        showApplicationIcons: true, commandAliases: aliases)
    }

    static func json(_ value: Any) -> Data {
        try! JSONSerialization.data(withJSONObject: value, options: [.fragmentsAllowed])
    }

    static func object(_ document: BackupDocument) -> [String: Any] {
        try! JSONSerialization.jsonObject(with: document.encoded()) as! [String: Any]
    }

    // MARK: Encoding helpers

    static func gzip(_ data: Data) -> Data {
        let capacity = data.count + 1024
        var deflated = Data(count: capacity)
        let size = deflated.withUnsafeMutableBytes { out in
            data.withUnsafeBytes { input in
                compression_encode_buffer(out.baseAddress!.assumingMemoryBound(to: UInt8.self), capacity,
                                          input.baseAddress!.assumingMemoryBound(to: UInt8.self), input.count, nil, COMPRESSION_ZLIB)
            }
        }
        deflated.count = size
        var output = Data([0x1F, 0x8B, 8, 0, 0, 0, 0, 0, 0, 3])
        output += deflated
        var crc = CRC32.checksum(data).littleEndian
        var length = UInt32(truncatingIfNeeded: data.count).littleEndian
        output += Data(bytes: &crc, count: 4)
        output += Data(bytes: &length, count: 4)
        return output
    }

    static func container(header: Any, payload: Data) -> Data {
        let compressed = gzip(json(header))
        var length = UInt32(compressed.count).littleEndian
        return Data("RAYCFG3\n".utf8) + Data(bytes: &length, count: 4) + compressed + payload
    }

    static func encryptCBC(_ data: Data, key: Data, iv: Data) -> Data {
        var output = Data(count: data.count + kCCBlockSizeAES128)
        let capacity = output.count
        var moved = 0
        _ = output.withUnsafeMutableBytes { out in
            data.withUnsafeBytes { input in
                key.withUnsafeBytes { key in
                    iv.withUnsafeBytes { iv in
                        CCCrypt(CCOperation(kCCEncrypt), CCAlgorithm(kCCAlgorithmAES), CCOptions(kCCOptionPKCS7Padding),
                                key.baseAddress, key.count, iv.baseAddress, input.baseAddress, input.count, out.baseAddress, capacity, &moved)
                    }
                }
            }
        }
        output.count = moved
        return output
    }

    static func encryptGCM(_ data: Data, password: String, salt: Data, iv: Data) throws -> (ciphertext: Data, tag: Data) {
        let key = try RaycastCrypto.scrypt(password: Data(password.utf8), salt: salt, n: 16384, r: 8, p: 1, length: 32)
        let box = try AES.GCM.seal(data, using: SymmetricKey(data: key), nonce: AES.GCM.Nonce(data: iv))
        return (box.ciphertext, box.tag)
    }

    static func hex(_ data: Data) -> String { data.map { String(format: "%02x", $0) }.joined() }

    static func data(hex: String) -> Data {
        var data = Data()
        var index = hex.startIndex
        while index < hex.endIndex {
            let next = hex.index(index, offsetBy: 2)
            data.append(UInt8(hex[index..<next], radix: 16)!)
            index = next
        }
        return data
    }
}
