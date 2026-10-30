import Foundation

/// Unkeyed BLAKE2b-512 (RFC 7693), the prehash of minisign's "ED" signatures. CryptoKit has no BLAKE2, and
/// update archives are hashed in chunks so they never have to fit in memory.
struct BLAKE2b512 {
    static let digestSize = 64
    private static let blockSize = 128

    private static let iv: [UInt64] = [
        0x6a09_e667_f3bc_c908, 0xbb67_ae85_84ca_a73b, 0x3c6e_f372_fe94_f82b, 0xa54f_f53a_5f1d_36f1,
        0x510e_527f_ade6_82d1, 0x9b05_688c_2b3e_6c1f, 0x1f83_d9ab_fb41_bd6b, 0x5be0_cd19_137e_2179,
    ]

    private static let sigma: [[Int]] = [
        [0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15],
        [14, 10, 4, 8, 9, 15, 13, 6, 1, 12, 0, 2, 11, 7, 5, 3],
        [11, 8, 12, 0, 5, 2, 15, 13, 10, 14, 3, 6, 7, 1, 9, 4],
        [7, 9, 3, 1, 13, 12, 11, 14, 2, 6, 5, 10, 4, 0, 15, 8],
        [9, 0, 5, 7, 2, 4, 10, 15, 14, 1, 11, 12, 6, 8, 3, 13],
        [2, 12, 6, 10, 0, 11, 8, 3, 4, 13, 7, 5, 15, 14, 1, 9],
        [12, 5, 1, 15, 14, 13, 4, 10, 0, 7, 6, 3, 9, 2, 8, 11],
        [13, 11, 7, 14, 12, 1, 3, 9, 5, 0, 15, 4, 8, 6, 2, 10],
        [6, 15, 14, 9, 11, 3, 0, 8, 12, 2, 13, 7, 1, 4, 10, 5],
        [10, 2, 8, 4, 7, 6, 1, 5, 15, 11, 9, 14, 3, 12, 13, 0],
    ]

    private var state: [UInt64]
    private var buffer: [UInt8] = []
    /// Bytes compressed so far. 128 bits in the spec; 64 bits covers any file Prism downloads.
    private var counter: UInt64 = 0

    init() {
        state = Self.iv
        // Parameter block: digest length 64, no key, fanout 1, depth 1.
        state[0] ^= 0x0101_0000 ^ UInt64(Self.digestSize)
        buffer.reserveCapacity(Self.blockSize)
    }

    mutating func update(_ data: some DataProtocol) {
        for region in data.regions {
            region.withUnsafeBytes { bytes in
                var offset = 0
                while offset < bytes.count {
                    // Keep the last block buffered: it must be compressed with the final flag.
                    if buffer.count == Self.blockSize {
                        counter &+= UInt64(Self.blockSize)
                        compress(buffer, last: false)
                        buffer.removeAll(keepingCapacity: true)
                    }
                    let take = min(Self.blockSize - buffer.count, bytes.count - offset)
                    buffer.append(contentsOf: bytes[offset..<offset + take])
                    offset += take
                }
            }
        }
    }

    mutating func finalize() -> Data {
        counter &+= UInt64(buffer.count)
        buffer += [UInt8](repeating: 0, count: Self.blockSize - buffer.count)
        compress(buffer, last: true)
        var digest = Data(capacity: Self.digestSize)
        for word in state {
            withUnsafeBytes(of: word.littleEndian) { digest.append(contentsOf: $0) }
        }
        return digest
    }

    static func hash(_ data: some DataProtocol) -> Data {
        var hasher = BLAKE2b512()
        hasher.update(data)
        return hasher.finalize()
    }

    private mutating func compress(_ block: [UInt8], last: Bool) {
        var m = [UInt64](repeating: 0, count: 16)
        block.withUnsafeBytes { bytes in
            for i in 0..<16 { m[i] = UInt64(littleEndian: bytes.loadUnaligned(fromByteOffset: i * 8, as: UInt64.self)) }
        }
        var v = state + Self.iv
        v[12] ^= counter
        if last { v[14] = ~v[14] }

        @inline(__always) func mix(_ a: Int, _ b: Int, _ c: Int, _ d: Int, _ x: UInt64, _ y: UInt64) {
            v[a] = v[a] &+ v[b] &+ x
            v[d] = (v[d] ^ v[a]).rotatedRight(32)
            v[c] = v[c] &+ v[d]
            v[b] = (v[b] ^ v[c]).rotatedRight(24)
            v[a] = v[a] &+ v[b] &+ y
            v[d] = (v[d] ^ v[a]).rotatedRight(16)
            v[c] = v[c] &+ v[d]
            v[b] = (v[b] ^ v[c]).rotatedRight(63)
        }
        for round in 0..<12 {
            let s = Self.sigma[round % 10]
            mix(0, 4, 8, 12, m[s[0]], m[s[1]])
            mix(1, 5, 9, 13, m[s[2]], m[s[3]])
            mix(2, 6, 10, 14, m[s[4]], m[s[5]])
            mix(3, 7, 11, 15, m[s[6]], m[s[7]])
            mix(0, 5, 10, 15, m[s[8]], m[s[9]])
            mix(1, 6, 11, 12, m[s[10]], m[s[11]])
            mix(2, 7, 8, 13, m[s[12]], m[s[13]])
            mix(3, 4, 9, 14, m[s[14]], m[s[15]])
        }
        for i in 0..<8 { state[i] ^= v[i] ^ v[i + 8] }
    }
}

private extension UInt64 {
    @inline(__always) func rotatedRight(_ count: UInt64) -> UInt64 {
        (self >> count) | (self << (64 - count))
    }
}
