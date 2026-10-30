import Compression
import Foundation

/// Unpacks the updater's `.app.tar.gz` with the rules of `update_signature.rs`: every entry is a regular file or
/// directory under `Prism.app/`, with no links, absolute paths or `..`, at most 1 GiB and 20,000 entries.
/// Nothing outside the destination directory can be written.
enum UpdateArchive {
    static let appName = "Prism.app"
    static let maximumSize: UInt64 = 1024 * 1024 * 1024
    static let maximumEntries = 20_000

    enum Failure: Error, Equatable {
        case invalidArchive
        case unsupportedEntry(String)
        case tooLarge
        case writeFailed
    }

    /// Extracts `archive` into `directory` and returns the extracted `Prism.app`.
    static func extract(_ archive: URL, into directory: URL) throws(Failure) -> URL {
        let tar = directory.appending(path: ".prism-update.tar")
        defer { try? FileManager.default.removeItem(at: tar) }
        // Headers and padding add a little to the content limit.
        try Gzip.decompress(archive, to: tar, limit: maximumSize + 64 * 1024 * 1024)
        try Tar.extract(tar, into: directory)
        let app = directory.appending(path: appName, directoryHint: .isDirectory)
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: app.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            throw .invalidArchive
        }
        return app
    }
}

// MARK: - gzip

enum Gzip {
    /// Inflates a single-member gzip file in chunks, checking its CRC-32 and length. The decoder may read ahead,
    /// so it only gets the bytes between the header and the 8-byte trailer, which is read from the end.
    static func decompress(_ source: URL, to destination: URL, limit: UInt64) throws(UpdateArchive.Failure) {
        guard let input = try? FileHandle(forReadingFrom: source),
              let size = try? input.seekToEnd(), size >= 18, (try? input.seek(toOffset: 0)) != nil
        else { throw .invalidArchive }
        defer { try? input.close() }
        guard FileManager.default.createFile(atPath: destination.path, contents: nil),
              let output = try? FileHandle(forWritingTo: destination)
        else { throw .writeFailed }
        defer { try? output.close() }

        // Bytes of the deflate stream not yet handed to `pending`.
        var unread = size - 8
        var pending = Data()
        func refill() throws(UpdateArchive.Failure) {
            guard unread > 0 else { return }
            let chunk: Data?
            do { chunk = try input.read(upToCount: Int(min(unread, 1 << 16))) } catch { throw .invalidArchive }
            guard let chunk, !chunk.isEmpty else { throw .invalidArchive }
            unread -= UInt64(chunk.count)
            pending += chunk
        }
        func take(_ count: Int) throws(UpdateArchive.Failure) -> Data {
            while pending.count < count {
                guard unread > 0 else { throw .invalidArchive }
                try refill()
            }
            let bytes = Data(pending.prefix(count))
            pending.removeFirst(count)
            return bytes
        }
        func skipString() throws(UpdateArchive.Failure) {
            while try take(1).first != 0 {}
        }

        let header = try take(10)
        guard header[0] == 0x1F, header[1] == 0x8B, header[2] == 8 else { throw .invalidArchive }
        let flags = header[3]
        guard flags & 0xE0 == 0 else { throw .invalidArchive }
        if flags & 0x04 != 0 {
            let length = try take(2)
            _ = try take(Int(length[0]) | Int(length[1]) << 8)
        }
        if flags & 0x08 != 0 { try skipString() }
        if flags & 0x10 != 0 { try skipString() }
        if flags & 0x02 != 0 { _ = try take(2) }

        // COMPRESSION_ZLIB is raw DEFLATE (RFC 1951), the gzip payload.
        let stream = UnsafeMutablePointer<compression_stream>.allocate(capacity: 1)
        defer { stream.deallocate() }
        guard compression_stream_init(stream, COMPRESSION_STREAM_DECODE, COMPRESSION_ZLIB) == COMPRESSION_STATUS_OK else {
            throw .invalidArchive
        }
        defer { compression_stream_destroy(stream) }

        let capacity = 1 << 16
        let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: capacity)
        defer { buffer.deallocate() }
        var crc = CRC32()
        var written: UInt64 = 0
        var finished = false
        while !finished {
            if pending.isEmpty { try refill() }
            let last = unread == 0
            let (status, consumed, produced) = pending.withUnsafeBytes { (raw: UnsafeRawBufferPointer) -> (compression_status, Int, Data) in
                // The source pointer must be valid even when there is no input left; nothing is read from it then.
                stream.pointee.src_ptr = raw.bindMemory(to: UInt8.self).baseAddress ?? UnsafePointer(buffer)
                stream.pointee.src_size = raw.count
                stream.pointee.dst_ptr = buffer
                stream.pointee.dst_size = capacity
                let status = compression_stream_process(stream, last ? Int32(COMPRESSION_STREAM_FINALIZE.rawValue) : 0)
                return (status, raw.count - stream.pointee.src_size, Data(bytes: buffer, count: capacity - stream.pointee.dst_size))
            }
            guard status != COMPRESSION_STATUS_ERROR else { throw .invalidArchive }
            finished = status == COMPRESSION_STATUS_END
            pending.removeFirst(consumed)
            // Truncated deflate data: no input left and no progress.
            if last, !finished, consumed == 0, produced.isEmpty { throw .invalidArchive }
            if !produced.isEmpty {
                written += UInt64(produced.count)
                guard written <= limit else { throw .tooLarge }
                crc.update(produced)
                do { try output.write(contentsOf: produced) } catch { throw .writeFailed }
            }
        }

        guard (try? input.seek(toOffset: size - 8)) != nil, let trailer = try? input.read(upToCount: 8), trailer.count == 8 else {
            throw .invalidArchive
        }
        let expectedCRC = trailer.prefix(4).enumerated().reduce(UInt32(0)) { $0 | UInt32($1.element) << (8 * $1.offset) }
        let expectedSize = trailer.suffix(4).enumerated().reduce(UInt32(0)) { $0 | UInt32($1.element) << (8 * $1.offset) }
        guard crc.value == expectedCRC, UInt32(truncatingIfNeeded: written) == expectedSize else { throw .invalidArchive }
    }
}

struct CRC32 {
    private static let table: [UInt32] = (0..<256).map { index in
        (0..<8).reduce(UInt32(index)) { value, _ in value & 1 != 0 ? 0xEDB8_8320 ^ (value >> 1) : value >> 1 }
    }

    private var state: UInt32 = 0xFFFF_FFFF

    var value: UInt32 { ~state }

    mutating func update(_ data: Data) {
        for byte in data {
            state = Self.table[Int((state ^ UInt32(byte)) & 0xFF)] ^ (state >> 8)
        }
    }
}

// MARK: - tar

enum Tar {
    private static let block = 512

    /// Extracts a ustar/GNU/pax archive. GNU long names (`L`) and pax headers (`x`) are applied to the next entry,
    /// as the Rust `tar` crate does; every other non-file, non-directory entry is rejected.
    static func extract(_ source: URL, into directory: URL) throws(UpdateArchive.Failure) {
        guard let input = try? FileHandle(forReadingFrom: source) else { throw .invalidArchive }
        defer { try? input.close() }
        func read(_ count: Int) throws(UpdateArchive.Failure) -> Data {
            guard count > 0 else { return Data() }
            guard let data = try? input.read(upToCount: count), data.count == count else { throw .invalidArchive }
            return data
        }
        func padding(_ size: UInt64) -> Int { Int((UInt64(block) - size % UInt64(block)) % UInt64(block)) }

        var total: UInt64 = 0
        var entries = 0
        var longName: String?
        var pax: [String: String] = [:]
        while true {
            let header = try read(block)
            if header.allSatisfy({ $0 == 0 }) { break }
            guard checksumMatches(header) else { throw .invalidArchive }
            let type = header[header.startIndex + 156]
            var size = try octal(header, offset: 124, length: 12)

            switch type {
            case UInt8(ascii: "L"), UInt8(ascii: "x"):
                guard size <= 64 * 1024 else { throw .invalidArchive }
                let body = try read(Int(size))
                _ = try read(padding(size))
                if type == UInt8(ascii: "L") {
                    longName = String(decoding: body.prefix { $0 != 0 }, as: UTF8.self)
                } else {
                    pax.merge(try paxRecords(body)) { $1 }
                }
                continue
            default:
                break
            }

            if let paxSize = pax["size"] {
                guard let value = UInt64(paxSize) else { throw .invalidArchive }
                size = value
            }
            let name = pax["path"] ?? longName ?? ustarName(header)
            longName = nil
            pax = [:]
            let isFile = type == UInt8(ascii: "0") || type == 0
            let isDirectory = type == UInt8(ascii: "5")
            guard isFile || isDirectory, let components = safeComponents(name) else { throw .unsupportedEntry(name) }

            total += size
            entries += 1
            guard total <= UpdateArchive.maximumSize, entries <= UpdateArchive.maximumEntries else { throw .tooLarge }

            let mode = try octal(header, offset: 100, length: 8)
            let destination = components.reduce(directory) { $0.appending(path: $1) }
            if isDirectory {
                guard size == 0 else { throw .invalidArchive }
                do {
                    try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o755])
                } catch { throw .writeFailed }
                continue
            }
            do {
                try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o755])
            } catch { throw .writeFailed }
            // Never follow anything already at the path; entries only create regular files.
            if (try? destination.resourceValues(forKeys: [.isSymbolicLinkKey]))?.isSymbolicLink == true { throw .unsupportedEntry(name) }
            guard FileManager.default.createFile(atPath: destination.path, contents: nil, attributes: [.posixPermissions: mode & 0o111 != 0 ? 0o755 : 0o644]),
                  let output = try? FileHandle(forWritingTo: destination)
            else { throw .writeFailed }
            var remaining = size
            do {
                defer { try? output.close() }
                while remaining > 0 {
                    let chunk = try read(Int(min(remaining, 1 << 20)))
                    do { try output.write(contentsOf: chunk) } catch { throw UpdateArchive.Failure.writeFailed }
                    remaining -= UInt64(chunk.count)
                }
            }
            _ = try read(padding(size))
        }
    }

    /// Path components under `Prism.app`, or nil for anything that could leave the destination.
    static func safeComponents(_ path: String) -> [String]? {
        guard !path.hasPrefix("/") else { return nil }
        let components = path.split(separator: "/").map(String.init)
        guard components.first == UpdateArchive.appName,
              components.allSatisfy({ $0 != "." && $0 != ".." && !$0.contains("\0") })
        else { return nil }
        return components
    }

    private static func ustarName(_ header: Data) -> String {
        func field(_ offset: Int, _ length: Int) -> String {
            let bytes = header[header.startIndex + offset..<header.startIndex + offset + length]
            return String(decoding: bytes.prefix { $0 != 0 }, as: UTF8.self)
        }
        let name = field(0, 100)
        let magic = field(257, 6)
        let prefix = magic.hasPrefix("ustar") ? field(345, 155) : ""
        return prefix.isEmpty ? name : prefix + "/" + name
    }

    private static func octal(_ header: Data, offset: Int, length: Int) throws(UpdateArchive.Failure) -> UInt64 {
        let bytes = header[header.startIndex + offset..<header.startIndex + offset + length]
        // GNU base-256 sizes are only needed beyond 8 GiB, far above the limit.
        guard bytes.first.map({ $0 & 0x80 == 0 }) ?? false else { throw .tooLarge }
        let text = String(decoding: bytes.drop { $0 == 0x20 }.prefix { $0 != 0 && $0 != 0x20 }, as: UTF8.self)
        if text.isEmpty { return 0 }
        guard let value = UInt64(text, radix: 8) else { throw .invalidArchive }
        return value
    }

    private static func checksumMatches(_ header: Data) -> Bool {
        guard let stored = try? octal(header, offset: 148, length: 8) else { return false }
        var sum: UInt64 = 0
        for (index, byte) in header.enumerated() {
            sum += (148..<156).contains(index) ? 0x20 : UInt64(byte)
        }
        return sum == stored
    }

    /// pax records: "<length> <key>=<value>\n".
    private static func paxRecords(_ body: Data) throws(UpdateArchive.Failure) -> [String: String] {
        var records: [String: String] = [:]
        var bytes = Substring(String(decoding: body, as: UTF8.self))
        while !bytes.isEmpty, bytes.first != "\0" {
            guard let space = bytes.firstIndex(of: " "), let length = Int(bytes[..<space]), length > 0,
                  let end = bytes.utf8.index(bytes.startIndex, offsetBy: length, limitedBy: bytes.endIndex)
            else { throw .invalidArchive }
            let record = bytes[bytes.index(after: space)..<end].dropLast()
            if let equals = record.firstIndex(of: "=") {
                records[String(record[..<equals])] = String(record[record.index(after: equals)...])
            }
            bytes = bytes[end...]
        }
        return records
    }
}
