import CommonCrypto
import CryptoKit
import Foundation

/// The ciphers Raycast exports use. Keys are zeroed as soon as decryption ends.
enum RaycastCrypto {
    struct Failure: Error {}

    static func sha256(_ data: Data) -> Data { Data(SHA256.hash(data: data)) }

    /// AES-256-CBC with PKCS#7 padding, as classic encrypted `.rayconfig` files use.
    static func decryptCBC(_ ciphertext: Data, key: Data, iv: Data) throws -> Data {
        guard key.count == kCCKeySizeAES256, iv.count == kCCBlockSizeAES128 else { throw Failure() }
        var output = Data(count: ciphertext.count + kCCBlockSizeAES128)
        let capacity = output.count
        var moved = 0
        let status = output.withUnsafeMutableBytes { out in
            ciphertext.withUnsafeBytes { input in
                key.withUnsafeBytes { key in
                    iv.withUnsafeBytes { iv in
                        CCCrypt(CCOperation(kCCDecrypt), CCAlgorithm(kCCAlgorithmAES), CCOptions(kCCOptionPKCS7Padding),
                                key.baseAddress, key.count, iv.baseAddress, input.baseAddress, input.count,
                                out.baseAddress, capacity, &moved)
                    }
                }
            }
        }
        guard status == kCCSuccess else { throw Failure() }
        output.count = moved
        return output
    }

    /// AES-256-GCM with a 12- or 16-byte IV and a separate 16-byte tag.
    static func decryptGCM(_ ciphertext: Data, key: Data, iv: Data, tag: Data) throws -> Data {
        do {
            let box = try AES.GCM.SealedBox(nonce: AES.GCM.Nonce(data: iv), ciphertext: ciphertext, tag: tag)
            return try AES.GCM.open(box, using: SymmetricKey(data: key))
        } catch {
            throw Failure()
        }
    }

    static func pbkdf2SHA256(password: Data, salt: Data, iterations: UInt32, length: Int) throws -> Data {
        var output = Data(count: length)
        let status = output.withUnsafeMutableBytes { out in
            password.withUnsafeBytes { password in
                salt.withUnsafeBytes { salt in
                    CCKeyDerivationPBKDF(CCPBKDFAlgorithm(kCCPBKDF2),
                                         password.baseAddress?.assumingMemoryBound(to: CChar.self), password.count,
                                         salt.baseAddress?.assumingMemoryBound(to: UInt8.self), salt.count,
                                         CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA256), iterations,
                                         out.baseAddress?.assumingMemoryBound(to: UInt8.self), length)
                }
            }
        }
        guard status == kCCSuccess else { throw Failure() }
        return output
    }

    /// scrypt (RFC 7914). Raycast uses N=16384, r=8, p=1, which needs 16 MiB while it runs.
    static func scrypt(password: Data, salt: Data, n: Int, r: Int, p: Int, length: Int) throws -> Data {
        guard n > 1, n & (n - 1) == 0, r > 0, p > 0, r * p < 1 << 30 else { throw Failure() }
        let blockWords = 32 * r
        var blocks = try pbkdf2SHA256(password: password, salt: salt, iterations: 1, length: p * 128 * r)
        defer { blocks.resetBytes(in: 0..<blocks.count) }
        let words = UnsafeMutablePointer<UInt32>.allocate(capacity: p * blockWords)
        let memory = UnsafeMutablePointer<UInt32>.allocate(capacity: n * blockWords)
        let scratch = UnsafeMutablePointer<UInt32>.allocate(capacity: blockWords * 2 + 16)
        defer {
            words.update(repeating: 0, count: p * blockWords); words.deallocate()
            memory.update(repeating: 0, count: n * blockWords); memory.deallocate()
            scratch.update(repeating: 0, count: blockWords * 2 + 16); scratch.deallocate()
        }
        blocks.withUnsafeBytes { raw in
            for index in 0..<(p * blockWords) { words[index] = UInt32(littleEndian: raw.loadUnaligned(fromByteOffset: index * 4, as: UInt32.self)) }
        }
        for block in 0..<p {
            romix(words + block * blockWords, r: r, n: n, memory: memory, scratch: scratch)
        }
        blocks.withUnsafeMutableBytes { raw in
            for index in 0..<(p * blockWords) { raw.storeBytes(of: words[index].littleEndian, toByteOffset: index * 4, as: UInt32.self) }
        }
        return try pbkdf2SHA256(password: password, salt: blocks, iterations: 1, length: length)
    }

    private static func romix(_ x: UnsafeMutablePointer<UInt32>, r: Int, n: Int, memory: UnsafeMutablePointer<UInt32>,
                              scratch: UnsafeMutablePointer<UInt32>) {
        let blockWords = 32 * r
        for index in 0..<n {
            (memory + index * blockWords).update(from: x, count: blockWords)
            blockMix(x, r: r, scratch: scratch)
        }
        for _ in 0..<n {
            let j = Int(x[(2 * r - 1) * 16]) & (n - 1)
            let v = memory + j * blockWords
            for word in 0..<blockWords { x[word] ^= v[word] }
            blockMix(x, r: r, scratch: scratch)
        }
    }

    private static func blockMix(_ b: UnsafeMutablePointer<UInt32>, r: Int, scratch: UnsafeMutablePointer<UInt32>) {
        let y = scratch
        let x = scratch + 32 * r
        x.update(from: b + (2 * r - 1) * 16, count: 16)
        for index in 0..<(2 * r) {
            let block = b + index * 16
            for word in 0..<16 { x[word] ^= block[word] }
            salsa20_8(x)
            // Even blocks go to the first half of the output, odd blocks to the second.
            let destination = (index % 2 == 0 ? index / 2 : r + index / 2) * 16
            (y + destination).update(from: x, count: 16)
        }
        b.update(from: y, count: 32 * r)
    }

    private static func salsa20_8(_ block: UnsafeMutablePointer<UInt32>) {
        var x0 = block[0], x1 = block[1], x2 = block[2], x3 = block[3], x4 = block[4], x5 = block[5], x6 = block[6], x7 = block[7]
        var x8 = block[8], x9 = block[9], x10 = block[10], x11 = block[11], x12 = block[12], x13 = block[13], x14 = block[14], x15 = block[15]
        @inline(__always) func rotate(_ value: UInt32, _ count: UInt32) -> UInt32 { (value << count) | (value >> (32 - count)) }
        for _ in 0..<4 {
            x4 ^= rotate(x0 &+ x12, 7); x8 ^= rotate(x4 &+ x0, 9); x12 ^= rotate(x8 &+ x4, 13); x0 ^= rotate(x12 &+ x8, 18)
            x9 ^= rotate(x5 &+ x1, 7); x13 ^= rotate(x9 &+ x5, 9); x1 ^= rotate(x13 &+ x9, 13); x5 ^= rotate(x1 &+ x13, 18)
            x14 ^= rotate(x10 &+ x6, 7); x2 ^= rotate(x14 &+ x10, 9); x6 ^= rotate(x2 &+ x14, 13); x10 ^= rotate(x6 &+ x2, 18)
            x3 ^= rotate(x15 &+ x11, 7); x7 ^= rotate(x3 &+ x15, 9); x11 ^= rotate(x7 &+ x3, 13); x15 ^= rotate(x11 &+ x7, 18)
            x1 ^= rotate(x0 &+ x3, 7); x2 ^= rotate(x1 &+ x0, 9); x3 ^= rotate(x2 &+ x1, 13); x0 ^= rotate(x3 &+ x2, 18)
            x6 ^= rotate(x5 &+ x4, 7); x7 ^= rotate(x6 &+ x5, 9); x4 ^= rotate(x7 &+ x6, 13); x5 ^= rotate(x4 &+ x7, 18)
            x11 ^= rotate(x10 &+ x9, 7); x8 ^= rotate(x11 &+ x10, 9); x9 ^= rotate(x8 &+ x11, 13); x10 ^= rotate(x9 &+ x8, 18)
            x12 ^= rotate(x15 &+ x14, 7); x13 ^= rotate(x12 &+ x15, 9); x14 ^= rotate(x13 &+ x12, 13); x15 ^= rotate(x14 &+ x13, 18)
        }
        block[0] &+= x0; block[1] &+= x1; block[2] &+= x2; block[3] &+= x3; block[4] &+= x4; block[5] &+= x5; block[6] &+= x6; block[7] &+= x7
        block[8] &+= x8; block[9] &+= x9; block[10] &+= x10; block[11] &+= x11; block[12] &+= x12; block[13] &+= x13; block[14] &+= x14; block[15] &+= x15
    }
}
