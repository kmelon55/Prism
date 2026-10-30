import Foundation
import Testing
@testable import PrismBackup

/// Ports of the decoding half of `raycast.test.ts`. Every fixture is generated here.
@Suite struct RaycastFileTests {
    static var classic: [String: Any] { [
        "builtin_package_snippets": ["snippets": [["name": "Greeting", "text": "Hello", "keyword": ";hello"]]],
        "builtin_package_quicklinks": ["quicklinks": [["name": "Search", "url": "https://example.com/?q={Query}"]]],
        "builtin_package_rootSearch": ["rootSearch": [
            ["key": "builtin_command_windowManagement_leftHalf", "hotkey": "control-option-123", "searchTerms": "left"],
            ["key": "builtin_command_windowManagement_rightHalf", "hotkey": "control-option-124"],
            ["path": "/Applications/Example.app", "hotkey": "command-shift-0", "searchTerms": "ex"],
            ["key": "extension_unknown", "hotkey": "command-1"],
        ]],
    ] }

    static func decoded(_ data: Data, password: String? = nil) throws -> NSDictionary {
        try #require(RaycastFile.decode(data, password: password) as? NSDictionary)
    }

    static func failure(_ data: Data, password: String? = nil) -> RaycastFile.Failure? {
        do {
            _ = try RaycastFile.decode(data, password: password)
            return nil
        } catch {
            return error as? RaycastFile.Failure
        }
    }

    @Test func knownAnswerVectors() throws {
        // RFC 7914 §12, and a Node.js `crypto.scryptSync` vector with Raycast's parameters.
        let rfc = try RaycastCrypto.scrypt(password: Data("password".utf8), salt: Data("NaCl".utf8), n: 1024, r: 8, p: 16, length: 64)
        #expect(Fixtures.hex(rfc) == "fdbabe1c9d3472007856e7190d01e9fe7c6ad7cbc8237830e77376634b3731622eaf30d92e22a3886ff109279d9830dac727afb94a83ee6d8360cbdfa2cc0640")
        let key = try RaycastCrypto.scrypt(password: Data("export password".utf8), salt: Data(repeating: 31, count: 16), n: 16384, r: 8, p: 1, length: 32)
        #expect(Fixtures.hex(key) == "d38111826bab7678881e3000f4b99504f67bfee3bdc521703c573164aafdf30a")
        // Node.js AES-256-GCM with a 16-byte IV, and Node.js gzip.
        let plain = try RaycastCrypto.decryptGCM(Fixtures.data(hex: "bc73bac006494a747c"), key: key, iv: Data(repeating: 12, count: 16),
                                                 tag: Fixtures.data(hex: "0a30e6e9f1a2fbd4f3ab29eb72d19de9"))
        #expect(String(decoding: plain, as: UTF8.self) == "hello gcm")
        #expect(try Gzip.decompress(Fixtures.data(hex: "1f8b0800000000000013ab564a54b232ac0500afac1b5607000000"), limit: 100) == Data(#"{"a":1}"#.utf8))
    }

    @Test func readsAnUnencryptedSchema3ContainerAndBuildsItsReview() throws {
        let data: [String: Any] = ["snippets": ["snippets": [["title": "Sample", "text": "Content"]]],
                                   "settings": ["commands": [["id": "c:r:windowManagement::*::leftHalf", "alias": "left"]]]]
        let file = Fixtures.container(header: ["schemaVersion": 3, "appVersion": "test"], payload: Fixtures.gzip(Fixtures.json(data)))
        // A slice that does not start at index 0, like a view into a larger buffer.
        let padded = (Data(count: 7) + file).dropFirst(7)
        let decoded = try Self.decoded(padded)
        #expect(decoded == data as NSDictionary)
        let rows = try RaycastPlan.build(decoded, context: RaycastImportContext())
        #expect(rows.contains { $0.category == .snippets && $0.title == "Sample" })
        #expect(rows.contains { $0.category == .aliases && $0.commandId == "window:left-half" && $0.value == "left" })
    }

    @Test func promptsForSchema3PasswordAndAuthenticatesTheTrailingTag() throws {
        let password = " Raycast X export "
        let iv = Data(repeating: 43, count: 16), salt = Data(repeating: 29, count: 16)
        let (ciphertext, tag) = try Fixtures.encryptGCM(Fixtures.gzip(Fixtures.json(Self.classic)), password: password, salt: salt, iv: iv)
        let file = Fixtures.container(header: ["schemaVersion": 3, "encryption": ["iv": Fixtures.hex(iv), "salt": Fixtures.hex(salt)]],
                                      payload: ciphertext + tag)
        #expect(Self.failure(file) == .password)
        #expect(Self.failure(file, password: password.trimmingCharacters(in: .whitespaces)) == .decrypt)
        #expect(try Self.decoded(file, password: password) == Self.classic as NSDictionary)
        var corrupted = file
        corrupted[corrupted.count - 1] ^= 1
        #expect(Self.failure(corrupted, password: password) == .decrypt)
    }

    @Test func rejectsMalformedSchema3FramingMetadataAndOversizedData() throws {
        let file = Fixtures.container(header: ["schemaVersion": 3], payload: Fixtures.gzip(Fixtures.json(Self.classic)))
        for length in [8, 11, 13] { #expect(Self.failure(file.prefix(length)) == .invalid) }
        for length: UInt32 in [0, UInt32(file.count), 1024 * 1024 + 1] {
            var invalid = file
            withUnsafeBytes(of: length.littleEndian) { invalid.replaceSubrange(8..<12, with: $0) }
            #expect(Self.failure(invalid) == .invalid)
        }
        #expect(Self.failure(Fixtures.container(header: ["schemaVersion": 4], payload: Fixtures.gzip(Fixtures.json(Self.classic)))) == .version)
        #expect(Self.failure(Fixtures.container(header: ["schemaVersion": 3, "encryption": ["iv": "bad", "salt": String(repeating: "00", count: 16)]],
                                                payload: Data(count: 32))) == .invalid)
        #expect(Self.failure(Fixtures.container(header: ["schemaVersion": 3, "encryption": [:]], payload: Data(count: 16))) == .invalid)
        #expect(Self.failure(Fixtures.container(header: ["schemaVersion": 3, "padding": String(repeating: "x", count: 1024 * 1024)],
                                                payload: Fixtures.gzip(Fixtures.json(Self.classic)))) == .size)
        #expect(Self.failure(Fixtures.container(header: ["schemaVersion": 3], payload: Fixtures.gzip(Data(count: 21 * 1024 * 1024)))) == .size)
    }

    @Test func readsPlainAndGzippedClassicExports() throws {
        #expect(try Self.decoded(Fixtures.json(Self.classic)) == Self.classic as NSDictionary)
        #expect(try Self.decoded(Fixtures.gzip(Fixtures.json(Self.classic))) == Self.classic as NSDictionary)
    }

    @Test func decryptsClassicCBCWithoutTrimmingThePassword() throws {
        let password = " password with spaces ", iv = Data(repeating: 19, count: 16)
        let file = iv + Fixtures.encryptCBC(Fixtures.gzip(Fixtures.json(Self.classic)), key: RaycastCrypto.sha256(Data(password.utf8)), iv: iv)
        #expect(Self.failure(file) == .password)
        #expect(Self.failure(file, password: password.trimmingCharacters(in: .whitespaces)) == .decrypt)
        #expect(try Self.decoded(file, password: password) == Self.classic as NSDictionary)
    }

    @Test(arguments: [12, 16]) func decryptsSchema2EnvelopeWithGCM(ivLength: Int) throws {
        let data: [String: Any] = ["snippets": ["snippets": [["title": "Sample", "text": "Content"]]], "settings": ["commands": []]]
        let iv = Data(repeating: 12, count: ivLength), salt = Data(repeating: 31, count: 16), password = "export password"
        let (ciphertext, tag) = try Fixtures.encryptGCM(Fixtures.gzip(Fixtures.json(data)), password: password, salt: salt, iv: iv)
        var envelope: [String: Any] = ["schemaVersion": 2, "data": Fixtures.hex(ciphertext),
                                       "encryption": ["iv": Fixtures.hex(iv), "salt": Fixtures.hex(salt), "authTag": Fixtures.hex(tag)]]
        let file = Fixtures.gzip(Fixtures.json(envelope))
        #expect(try Self.decoded(file, password: password) == data as NSDictionary)
        #expect(Self.failure(file, password: "wrong") == .decrypt)
        envelope["encryption"] = ["iv": Fixtures.hex(iv), "salt": Fixtures.hex(salt), "authTag": String(repeating: "00", count: 16)]
        #expect(Self.failure(Fixtures.json(envelope), password: password) == .decrypt)
    }

    @Test func rejectsNewerVersionsMalformedFilesAndDecompressionBombs() {
        #expect(Self.failure(Fixtures.json(["schemaVersion": 99, "data": ""])) == .version)
        #expect(Self.failure(Fixtures.json(["schemaVersion": 1, "data": "xz"])) == .invalid)
        #expect(Self.failure(Fixtures.gzip(Data(count: 21 * 1024 * 1024))) == .size)
        #expect(Self.failure(Data()) == .size)
        #expect(Self.failure(Data(repeating: 7, count: 33)) == .invalid)
        var damaged = Fixtures.gzip(Fixtures.json(Self.classic))
        damaged[damaged.count - 6] ^= 0xFF
        #expect(Self.failure(damaged) == .invalid)
    }
}
