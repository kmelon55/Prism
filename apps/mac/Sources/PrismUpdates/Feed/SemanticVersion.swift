import Foundation

/// A Semantic Versioning 2.0 version, compared by precedence as the Tauri updater's `semver` crate does.
/// A leading "v" is accepted, as in Tauri's feed parser.
struct SemanticVersion: Comparable, CustomStringConvertible, Sendable {
    let major: UInt64
    let minor: UInt64
    let patch: UInt64
    let prerelease: [String]
    let build: String

    init?(_ text: String) {
        var rest = Substring(text.trimmingCharacters(in: .whitespaces))
        if rest.first == "v" { rest = rest.dropFirst() }
        var build = ""
        if let plus = rest.firstIndex(of: "+") {
            build = String(rest[rest.index(after: plus)...])
            rest = rest[..<plus]
            guard Self.validIdentifiers(build, numeric: false) else { return nil }
        }
        var prerelease: [String] = []
        if let dash = rest.firstIndex(of: "-") {
            let text = String(rest[rest.index(after: dash)...])
            guard Self.validIdentifiers(text, numeric: true) else { return nil }
            prerelease = text.split(separator: ".").map(String.init)
            rest = rest[..<dash]
        }
        let core = rest.split(separator: ".", omittingEmptySubsequences: false)
        guard core.count == 3 else { return nil }
        var numbers: [UInt64] = []
        for part in core {
            guard let number = Self.numeric(part) else { return nil }
            numbers.append(number)
        }
        major = numbers[0]
        minor = numbers[1]
        patch = numbers[2]
        self.prerelease = prerelease
        self.build = build
    }

    var description: String {
        "\(major).\(minor).\(patch)" + (prerelease.isEmpty ? "" : "-" + prerelease.joined(separator: ".")) + (build.isEmpty ? "" : "+" + build)
    }

    /// Build metadata does not affect precedence.
    static func == (lhs: SemanticVersion, rhs: SemanticVersion) -> Bool {
        !(lhs < rhs) && !(rhs < lhs)
    }

    static func < (lhs: SemanticVersion, rhs: SemanticVersion) -> Bool {
        if (lhs.major, lhs.minor, lhs.patch) != (rhs.major, rhs.minor, rhs.patch) {
            return (lhs.major, lhs.minor, lhs.patch) < (rhs.major, rhs.minor, rhs.patch)
        }
        // A pre-release sorts before the release it precedes.
        switch (lhs.prerelease.isEmpty, rhs.prerelease.isEmpty) {
        case (true, true): return false
        case (true, false): return false
        case (false, true): return true
        case (false, false): break
        }
        for (left, right) in zip(lhs.prerelease, rhs.prerelease) where left != right {
            switch (numeric(Substring(left)), numeric(Substring(right))) {
            case let (l?, r?): return l < r
            case (_?, nil): return true
            case (nil, _?): return false
            case (nil, nil): return left < right
            }
        }
        return lhs.prerelease.count < rhs.prerelease.count
    }

    private static func numeric(_ part: Substring) -> UInt64? {
        guard !part.isEmpty, part.allSatisfy(\.isASCIIDigit), part == "0" || part.first != "0" else { return nil }
        return UInt64(part)
    }

    private static func validIdentifiers(_ text: String, numeric checkLeadingZeros: Bool) -> Bool {
        let parts = text.split(separator: ".", omittingEmptySubsequences: false)
        return parts.allSatisfy { part in
            !part.isEmpty && part.allSatisfy { $0.isASCIIDigit || $0.isASCIILetter || $0 == "-" }
                && (!checkLeadingZeros || !part.allSatisfy(\.isASCIIDigit) || part == "0" || part.first != "0")
        }
    }
}

private extension Character {
    var isASCIIDigit: Bool { isASCII && isNumber }
    var isASCIILetter: Bool { isASCII && isLetter }
}
