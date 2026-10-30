import Foundation

/// Decodes Raycast exports, ported from `raycastFile.ts`: plain or gzip JSON, classic AES-CBC, schema 1/2
/// envelopes with scrypt/AES-GCM, and the Raycast X `RAYCFG3` container. The password is used only here and is
/// never stored.
enum RaycastFile {
    static let maxBytes = 20 * 1024 * 1024
    static let maxHeaderBytes = 1024 * 1024
    private static let containerMagic = Data("RAYCFG3\n".utf8)

    enum Failure: Error, Equatable {
        case password, decrypt, invalid, version, size

        /// The message the Tauri import shows for each code.
        var message: String {
            switch self {
            case .password: "Enter the export password."
            case .decrypt: "Incorrect password or damaged file."
            case .size: "File exceeds 20 MB."
            case .version: "This Raycast export version is not supported yet."
            case .invalid: "This file is not a valid Raycast export."
            }
        }
    }

    static func decode(_ input: Data, password: String? = nil) throws -> Any {
        let input = Data(input)
        guard !input.isEmpty, input.count <= maxBytes else { throw Failure.size }
        if input.starts(with: containerMagic) { return try decodeContainer(input, password: password) }
        var bytes = input
        let prefix = String(decoding: input.prefix(64), as: UTF8.self).drop { $0.isWhitespace }
        if !Gzip.isGzip(bytes) && !prefix.hasPrefix("{") && !prefix.hasPrefix("[") {
            guard bytes.count >= 32, bytes.count % 16 == 0 else { throw Failure.invalid }
            guard let password else { throw Failure.password }
            var key = RaycastCrypto.sha256(Data(password.utf8))
            defer { key.resetBytes(in: 0..<key.count) }
            do {
                bytes = try RaycastCrypto.decryptCBC(bytes.dropFirst(16), key: key, iv: bytes.prefix(16))
            } catch {
                throw Failure.decrypt
            }
            guard Gzip.isGzip(bytes) else { throw Failure.decrypt }
        }
        let envelope = try json(unzip(bytes))
        guard let outer = envelope as? [String: Any], let version = outer["schemaVersion"] else { return envelope }
        let schema = (version as? NSNumber).flatMap { isNumber($0) ? $0.doubleValue : nil }
        guard schema == 1 || schema == 2 else { throw Failure.version }
        var payload = try hex(outer["data"])
        if let encryption = outer["encryption"], !(encryption is NSNull) {
            let fields = encryption as? [String: Any] ?? [:]
            payload = try decryptGCM(payload, encryption: fields, tag: hex(fields["authTag"]), password: password)
        }
        return try json(schema == 2 ? unzip(payload) : payload)
    }

    private static func decodeContainer(_ input: Data, password: String?) throws -> Any {
        let bytes = [UInt8](input)
        let prefixSize = containerMagic.count + 4
        guard bytes.count >= prefixSize else { throw Failure.invalid }
        let m = containerMagic.count
        let headerSize = Int(UInt32(bytes[m]) | UInt32(bytes[m + 1]) << 8 | UInt32(bytes[m + 2]) << 16 | UInt32(bytes[m + 3]) << 24)
        let payloadStart = prefixSize + headerSize
        guard headerSize > 0, headerSize <= maxHeaderBytes, payloadStart < bytes.count else { throw Failure.invalid }
        let headerBytes = Data(bytes[prefixSize..<payloadStart])
        guard Gzip.isGzip(headerBytes) else { throw Failure.invalid }
        let header = try json(unzip(headerBytes, limit: maxHeaderBytes)) as? [String: Any] ?? [:]
        guard let schema = header["schemaVersion"] as? NSNumber, isNumber(schema), schema.doubleValue == 3 else { throw Failure.version }
        var payload = Data(bytes[payloadStart...])
        if let encryption = header["encryption"], !(encryption is NSNull) {
            guard payload.count > 16 else { throw Failure.invalid }
            payload = try decryptGCM(payload.dropLast(16), encryption: encryption as? [String: Any] ?? [:],
                                     tag: payload.suffix(16), password: password)
        }
        guard Gzip.isGzip(payload) else { throw Failure.invalid }
        return try json(unzip(payload))
    }

    private static func decryptGCM(_ payload: Data, encryption: [String: Any], tag: Data, password: String?) throws -> Data {
        let iv = try hex(encryption["iv"]), salt = try hex(encryption["salt"])
        guard [12, 16].contains(iv.count), tag.count == 16, (8...64).contains(salt.count) else { throw Failure.invalid }
        guard let password else { throw Failure.password }
        var key = try RaycastCrypto.scrypt(password: Data(password.utf8), salt: salt, n: 16384, r: 8, p: 1, length: 32)
        defer { key.resetBytes(in: 0..<key.count) }
        do {
            return try RaycastCrypto.decryptGCM(Data(payload), key: key, iv: iv, tag: Data(tag))
        } catch {
            throw Failure.decrypt
        }
    }

    private static func unzip(_ data: Data, limit: Int = maxBytes) throws -> Data {
        guard Gzip.isGzip(data) else { return data }
        do {
            return try Gzip.decompress(data, limit: limit)
        } catch Gzip.Failure.tooLarge {
            throw Failure.size
        } catch {
            throw Failure.invalid
        }
    }

    private static func json(_ data: Data) throws -> Any {
        guard String(data: data, encoding: .utf8) != nil,
              let value = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
        else { throw Failure.invalid }
        return value
    }

    private static func hex(_ value: Any?) throws -> Data {
        guard let text = value as? String, text.utf8.count <= maxBytes * 2, text.utf8.count % 2 == 0 else { throw Failure.invalid }
        var data = Data(capacity: text.utf8.count / 2)
        var high: UInt8?
        for byte in text.utf8 {
            let nibble: UInt8
            switch byte {
            case 48...57: nibble = byte - 48
            case 65...70: nibble = byte - 55
            case 97...102: nibble = byte - 87
            default: throw Failure.invalid
            }
            if let value = high { data.append(value << 4 | nibble); high = nil } else { high = nibble }
        }
        return data
    }

    /// JSONSerialization returns booleans as NSNumber too; `schemaVersion: true` is not a version.
    static func isNumber(_ number: NSNumber) -> Bool { CFGetTypeID(number) != CFBooleanGetTypeID() }
}
