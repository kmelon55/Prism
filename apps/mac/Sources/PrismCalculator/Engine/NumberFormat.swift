import Foundation

/// Decimal-string helpers from `number-format.ts`, plus the exact number-to-text rules of the Rust and
/// JavaScript runtimes the Tauri app relied on, so copied values stay byte-for-byte the same.
enum NumberFormat {
    private static let decimal = Pattern(#"^([+-]?)([0-9]+)(\.[0-9]+)?([eE][+-]?[0-9]+)?$"#)
    private static let grouped = Pattern(#"^[+-]?(?:(?:[0-9]{1,3}(?:,[0-9]{3})+|[0-9]+)(?:\.[0-9]*)?|\.[0-9]+)$"#)
    private static let literal = Pattern(#"[0-9.,]+"#)
    private static let number = Pattern(#"[0-9]+(?:\.[0-9]+)?"#)

    /// Adds thousands separators without converting the decimal string to a lossy number.
    static func groupDecimal(_ value: String) -> String {
        guard let match = decimal.match(value), let integer = match[2] else { return value }
        return (match[1] ?? "") + groupDigits(integer) + (match[3] ?? "") + (match[4] ?? "")
    }

    /// Removes well-formed grouping; malformed grouping such as `1,00` is rejected rather than reinterpreted.
    static func ungroupDecimal(_ value: String) -> String? {
        grouped.matches(value) ? value.replacingOccurrences(of: ",", with: "") : nil
    }

    static func normalizeArithmeticExpression(_ value: String) -> String? {
        var valid = true
        let expression = literal.replace(in: value) { groups in
            let text = groups[0] ?? ""
            guard let normalized = ungroupDecimal(text) else {
                valid = false
                return text
            }
            return normalized
        }
        return valid ? expression : nil
    }

    static func groupExpression(_ value: String) -> String {
        number.replace(in: value) { groupDecimal($0[0] ?? "") }
    }

    private static func groupDigits(_ digits: String) -> String {
        var result = ""
        for (index, character) in digits.enumerated() {
            if index > 0, (digits.count - index) % 3 == 0 { result.append(",") }
            result.append(character)
        }
        return result
    }

    // MARK: Runtime number formatting

    /// The shortest round-trip digits of a finite double and the position of its decimal point:
    /// `value == 0.digits × 10^point`.
    private static func shortestDigits(_ value: Double) -> (negative: Bool, digits: String, point: Int) {
        // Swift's `description` is already the shortest round-trip representation; only its layout differs.
        let text = value.magnitude.description
        let parts = text.lowercased().split(separator: "e", maxSplits: 1)
        let mantissa = String(parts[0])
        let exponent = parts.count > 1 ? Int(parts[1]) ?? 0 : 0
        let pieces = mantissa.split(separator: ".", omittingEmptySubsequences: false)
        let integer = String(pieces[0])
        let fraction = pieces.count > 1 ? String(pieces[1]) : ""
        var digits = integer + fraction
        var point = integer.count + exponent
        let leading = digits.prefix { $0 == "0" }.count
        digits.removeFirst(leading)
        point -= leading
        while digits.hasSuffix("0") { digits.removeLast() }
        if digits.isEmpty { return (value.sign == .minus, "0", 1) }
        return (value.sign == .minus, digits, point)
    }

    /// Rust's `f64` `Display`: shortest round-trip digits, always positional, `-0` printed as `-0`.
    static func rustDisplay(_ value: Double) -> String {
        let (negative, digits, point) = shortestDigits(value)
        let sign = negative ? "-" : ""
        if digits == "0" { return sign + "0" }
        if point <= 0 { return sign + "0." + String(repeating: "0", count: -point) + digits }
        if point >= digits.count { return sign + digits + String(repeating: "0", count: point - digits.count) }
        let split = digits.index(digits.startIndex, offsetBy: point)
        return sign + digits[..<split] + "." + digits[split...]
    }

    /// JavaScript's `Number.prototype.toString()` (ECMAScript Number::toString with radix 10).
    static func javaScriptString(_ value: Double) -> String {
        if value.isNaN { return "NaN" }
        if value.isInfinite { return value < 0 ? "-Infinity" : "Infinity" }
        if value == 0 { return "0" }
        let (negative, digits, n) = shortestDigits(value)
        let sign = negative ? "-" : ""
        let k = digits.count
        if k <= n, n <= 21 { return sign + digits + String(repeating: "0", count: n - k) }
        if 0 < n, n <= 21 {
            let split = digits.index(digits.startIndex, offsetBy: n)
            return sign + digits[..<split] + "." + digits[split...]
        }
        if -6 < n, n <= 0 { return sign + "0." + String(repeating: "0", count: -n) + digits }
        let exponent = n - 1
        let exponentText = (exponent < 0 ? "-" : "+") + String(abs(exponent))
        let mantissa = k == 1 ? digits : String(digits.first!) + "." + digits.dropFirst()
        return sign + mantissa + "e" + exponentText
    }

    /// `Number(value.toPrecision(precision))`.
    static func rounded(_ value: Double, significantDigits precision: Int) -> Double {
        guard value.isFinite, value != 0 else { return value }
        return Double(String(format: "%.\(precision - 1)e", value)) ?? value
    }

    /// JavaScript's `Number.prototype.toFixed`: exact rounding with ties away from zero, and `-` for any
    /// negative input, so `(-0.001).toFixed(2)` is `-0.00`.
    static func javaScriptFixed(_ value: Double, digits: Int) -> String {
        guard value.isFinite else { return javaScriptString(value) }
        if value.magnitude >= 1e21 { return javaScriptString(value) }
        let sign = value < 0 ? "-" : ""
        let magnitude = value.magnitude
        // printf rounds the exact binary value half-to-even; JavaScript breaks exact ties upward.
        let wide = String(format: "%.\(digits + 30)f", magnitude)
        let fraction = wide.split(separator: ".").dropFirst().first.map(String.init) ?? ""
        let tail = fraction.dropFirst(digits)
        if tail.first == "5", tail.dropFirst().allSatisfy({ $0 == "0" }) {
            let step = pow(10, Double(-digits))
            return sign + String(format: "%.\(digits)f", magnitude + step / 2)
        }
        return sign + String(format: "%.\(digits)f", magnitude)
    }

    /// `Intl.NumberFormat("en-US", { maximumFractionDigits })`, grouped and without trailing zeros.
    static func label(_ value: Double, maximumFractionDigits: Int = 6) -> String {
        var text = String(format: "%.\(maximumFractionDigits)f", value)
        if text.contains(".") {
            while text.hasSuffix("0") { text.removeLast() }
            if text.hasSuffix(".") { text.removeLast() }
        }
        if text == "-0" { text = "0" }
        return groupDecimal(text)
    }
}
