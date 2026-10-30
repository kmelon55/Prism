import Compression
import Foundation

/// Bounded gzip (RFC 1952) decoding on top of the Compression framework's raw DEFLATE.
enum Gzip {
    enum Failure: Error, Equatable {
        case invalid
        /// The decompressed data would exceed the limit.
        case tooLarge
    }

    static func isGzip(_ data: Data) -> Bool {
        data.count >= 2 && data[data.startIndex] == 0x1F && data[data.startIndex + 1] == 0x8B
    }

    /// Decompresses one gzip member and checks its CRC and length. Stops as soon as the output passes `limit`.
    static func decompress(_ input: Data, limit: Int) throws -> Data {
        let bytes = [UInt8](input)
        guard bytes.count >= 18, bytes[0] == 0x1F, bytes[1] == 0x8B, bytes[2] == 8 else { throw Failure.invalid }
        let flags = bytes[3]
        var offset = 10
        if flags & 0x04 != 0 {
            guard offset + 2 <= bytes.count else { throw Failure.invalid }
            let extra = Int(bytes[offset]) | (Int(bytes[offset + 1]) << 8)
            offset += 2 + extra
        }
        for flag in [UInt8(0x08), 0x10] where flags & flag != 0 {
            while offset < bytes.count, bytes[offset] != 0 { offset += 1 }
            offset += 1
        }
        if flags & 0x02 != 0 { offset += 2 }
        guard offset < bytes.count - 8 else { throw Failure.invalid }

        // One member: the last 8 bytes are the trailer. The decoder must use up exactly the bytes before it.
        let trailer = bytes.count - 8
        let (output, consumed) = try inflate(bytes[offset..<trailer], limit: limit)
        guard consumed == trailer - offset else { throw Failure.invalid }
        let crc = UInt32(bytes[trailer]) | UInt32(bytes[trailer + 1]) << 8 | UInt32(bytes[trailer + 2]) << 16 | UInt32(bytes[trailer + 3]) << 24
        let size = UInt32(bytes[trailer + 4]) | UInt32(bytes[trailer + 5]) << 8 | UInt32(bytes[trailer + 6]) << 16 | UInt32(bytes[trailer + 7]) << 24
        guard crc == CRC32.checksum(output), size == UInt32(truncatingIfNeeded: output.count) else { throw Failure.invalid }
        return output
    }

    /// Raw DEFLATE. Returns the output and how many input bytes the stream used.
    private static func inflate(_ input: ArraySlice<UInt8>, limit: Int) throws -> (Data, Int) {
        var stream = compression_stream(dst_ptr: UnsafeMutablePointer<UInt8>(bitPattern: 1)!, dst_size: 0,
                                        src_ptr: UnsafePointer<UInt8>(bitPattern: 1)!, src_size: 0, state: nil)
        guard compression_stream_init(&stream, COMPRESSION_STREAM_DECODE, COMPRESSION_ZLIB) == COMPRESSION_STATUS_OK else {
            throw Failure.invalid
        }
        defer { compression_stream_destroy(&stream) }
        let chunkSize = 64 * 1024
        let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: chunkSize)
        defer { buffer.deallocate() }
        var output = Data()
        return try input.withUnsafeBufferPointer { source in
            stream.src_ptr = source.baseAddress!
            stream.src_size = source.count
            while true {
                stream.dst_ptr = buffer
                stream.dst_size = chunkSize
                let status = compression_stream_process(&stream, Int32(COMPRESSION_STREAM_FINALIZE.rawValue))
                let produced = chunkSize - stream.dst_size
                if output.count + produced > limit { throw Failure.tooLarge }
                output.append(buffer, count: produced)
                switch status {
                case COMPRESSION_STATUS_END:
                    return (output, source.count - stream.src_size)
                case COMPRESSION_STATUS_OK:
                    // No progress with input left means a truncated or corrupt stream.
                    if produced == 0 && stream.src_size == 0 { throw Failure.invalid }
                default:
                    throw Failure.invalid
                }
            }
        }
    }
}

enum CRC32 {
    private static let table: [UInt32] = (0..<256).map { index in
        var value = UInt32(index)
        for _ in 0..<8 { value = value & 1 == 1 ? 0xEDB8_8320 ^ (value >> 1) : value >> 1 }
        return value
    }

    static func checksum(_ data: Data) -> UInt32 {
        var crc: UInt32 = 0xFFFF_FFFF
        data.withUnsafeBytes { raw in
            for byte in raw { crc = table[Int((crc ^ UInt32(byte)) & 0xFF)] ^ (crc >> 8) }
        }
        return crc ^ 0xFFFF_FFFF
    }
}
