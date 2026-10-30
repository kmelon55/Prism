import Foundation

/// The Tauri application index's usage rules, shared by every palette row.
public enum Frecency {
    /// Tauri's `frecency_bonus`: log frequency plus a recency step, capped below a match tier.
    public static func bonus(count: Int, lastUsedAt: Int64, now: Int64) -> Double {
        let frequency = log(Double(max(0, count)) + 1) * 8
        let recency: Double = switch max(0, now - lastUsedAt) {
        case 0...3_600: 44
        case 3_601...86_400: 30
        case 86_401...604_800: 18
        case 604_801...2_592_000: 8
        default: 0
        }
        return min(72, frequency + recency)
    }

    /// Tauri's `application_id`: the bundle path's UTF-8 bytes as lowercase hex.
    public static func applicationID(path: String) -> String {
        path.utf8.map { String(format: "%02x", $0) }.joined()
    }

    public static func path(fromApplicationID id: String) -> String? {
        guard id.count.isMultiple(of: 2) else { return nil }
        var bytes: [UInt8] = []
        var index = id.startIndex
        while index < id.endIndex {
            let next = id.index(index, offsetBy: 2)
            guard let byte = UInt8(id[index..<next], radix: 16) else { return nil }
            bytes.append(byte)
            index = next
        }
        return String(bytes: bytes, encoding: .utf8)
    }
}
