import Foundation

/// Reads a large number with Korean myriad units: `123456789` is `1억 2,345만 6,789`, `120000000` is `1억 2천만`.
/// Groups of four digits take 만, 억, 조 and 경; a group that is a round thousand or hundred is read with 천 and 백.
enum KoreanNumber {
    private static let units = ["", "만", "억", "조", "경"]
    private static let plain = Pattern(#"^(-?)([0-9]+)(\.[0-9]+)?$"#)

    /// Shown to Korean speakers and in the Korean region, including an English-first Mac set to Korea (`en-KR`).
    static var isPreferred: Bool {
        Locale.preferredLanguages.contains { $0.hasPrefix("ko") } || Locale.current.region?.identifier == "KR"
    }

    /// The reading of a plain decimal string, or nil when it is below 10,000 or not a plain number.
    static func reading(_ value: String) -> String? {
        guard let match = plain.match(value), let digits = match[2] else { return nil }
        let integer = digits.drop { $0 == "0" }
        guard integer.count >= 5, integer.count <= units.count * 4 else { return nil }
        var groups: [Int] = []
        var end = integer.endIndex
        while end > integer.startIndex {
            let start = integer.index(end, offsetBy: -4, limitedBy: integer.startIndex) ?? integer.startIndex
            groups.append(Int(integer[start..<end]) ?? 0)
            end = start
        }
        var parts: [String] = []
        for (power, group) in groups.enumerated().reversed() where group != 0 {
            parts.append(read(group) + units[power])
        }
        var text = parts.joined(separator: " ")
        if let fraction = match[3] {
            text += groups[0] == 0 ? " 0" + fraction : fraction
        }
        return (match[1] ?? "") + text
    }

    /// The reading with a currency's Korean unit, such as `13만 8천원`.
    static func reading(_ value: String, currency: String) -> String? {
        guard let text = reading(value) else { return nil }
        return currency == "KRW" ? text + "원" : text
    }

    private static func read(_ group: Int) -> String {
        if group % 1000 == 0 { return "\(group / 1000)천" }
        if group >= 1000, group % 100 == 0 { return "\(group / 1000)천\(group / 100 % 10)백" }
        return NumberFormat.groupDecimal(String(group))
    }
}
