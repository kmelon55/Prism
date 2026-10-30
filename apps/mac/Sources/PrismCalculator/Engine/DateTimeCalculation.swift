import Foundation

/// Explicit calendar arithmetic and time-zone conversion from `datetime.ts`. Nothing is inferred from the
/// current date, the machine's locale or its time zone.
enum DateTimeCalculation {
    enum Kind: Sendable { case date, difference, timezone }

    struct Result: Equatable, Sendable {
        let kind: Kind
        /// The exact copy value, such as `2026-09-09`, `3 days` or `2026-09-06T00:00:00Z`.
        let result: String
        let context: String
        /// A short label for the row, such as `Asia/Seoul → UTC` or `Calendar days`.
        let summary: String
    }

    private static let date = "([0-9]{4}-[0-9]{2}-[0-9]{2})"
    private static let koreanDate = Pattern(#"([0-9]{4})년\s*([0-9]{1,2})월\s*([0-9]{1,2})일"#)
    private static let arithmetic = Pattern("^\(date)\\s*([+-])\\s*([0-9]+)\\s*(?:days?|일)$", caseInsensitive: true)
    private static let relative = Pattern("^\(date)\\s*(?:에서\\s*)?([0-9]+)\\s*일\\s*(후|뒤|전)$")
    private static let difference = Pattern("^\(date)\\s*-\\s*\(date)$")
    private static let interval = Pattern("^\(date)\\s*(?:to|부터|~|→)\\s*\(date)\\s*(?:까지)?\\s*(?:days?|일|차이)?$", caseInsensitive: true)
    private static let koreanDifference = Pattern("^\(date)\\s*(?:와|과)\\s*\(date)\\s*(?:날짜\\s*)?차이$")
    private static let timezone = Pattern(
        "^\(date)[T ]([0-9]{2}):([0-9]{2})(?::([0-9]{2}))?\\s*(Z|[+-][0-9]{2}:[0-9]{2})?"
            + "(?:\\s*([A-Za-z][A-Za-z0-9_+./-]*|서울|한국))?\\s+(?:to|in|->|→)\\s+([^\\s]+)$",
        caseInsensitive: true)
    private static let koreanDestination = Pattern(#"에서\s+(\S+?)(?:으로|로)$"#)
    private static let utcName = Pattern("^(?:utc|z)$", caseInsensitive: true)
    private static let ianaName = Pattern(#"^[A-Za-z_]+(?:/[A-Za-z0-9_+-]+)+$"#)

    static let maximumDays = 3_652_058
    private static let day: Int64 = 86_400

    /// Nil for unrelated or incomplete input; throws with an explanation for recognized invalid input.
    static func calculate(_ query: String) throws(AnswerError) -> Result? {
        if query.utf16.count > 256 || query.containsControlCharacter { return nil }
        let text = koreanDate.replace(in: query.jsTrimmed) { groups in
            "\(groups[1]!)-\(pad(groups[2]!))-\(pad(groups[3]!))"
        }
        if let match = arithmetic.match(text) {
            return try addDays(match[1]!, match[3]!, sign: match[2] == "+" ? 1 : -1)
        }
        if let match = relative.match(text) {
            return try addDays(match[1]!, match[2]!, sign: match[3] == "전" ? -1 : 1)
        }
        if let match = difference.match(text) {
            return try between(match[2]!, match[1]!)
        }
        if let match = interval.match(text) ?? koreanDifference.match(text) {
            return try between(match[1]!, match[2]!)
        }
        // An explicit Korean source/destination pair: "서울에서 UTC로".
        let converted = koreanDestination.replace(in: text) { " to \($0[1]!)" }
        guard let match = timezone.match(converted) else { return nil }
        let offset = match[5]
        let source = match[6]
        guard source != nil || offset != nil else { return nil }
        let midnight = try dateSeconds(match[1]!)
        let hours = Int64(match[2]!)!, minutes = Int64(match[3]!)!, seconds = Int64(match[4] ?? "0")!
        if hours > 23 || minutes > 59 || seconds > 59 {
            throw AnswerError(localized("Invalid time. Use 00:00:00 through 23:59:59; leap seconds are not supported."))
        }
        let wall = midnight + hours * 3600 + minutes * 60 + seconds
        let destination = try resolveZone(match[7]!)
        let origin: Zone? = if let source { try resolveZone(source) } else { nil }
        let instant: Int64
        if let origin {
            instant = try localInstant(wall: wall, zone: origin, explicitOffset: offset)
        } else {
            instant = wall - Int64(try offsetMinutes(offset!)) * 60
        }
        return Result(
            kind: .timezone,
            result: try zoneResult(instant, zone: destination),
            context: localized("\(origin?.name ?? offset!) → \(destination.name) · Device time-zone rules"),
            summary: "\(origin?.name ?? offset!) → \(destination.name)"
        )
    }

    private static func pad(_ text: String) -> String {
        text.count < 2 ? "0" + text : text
    }

    private static func invalidDate() -> AnswerError {
        AnswerError(localized("Invalid calendar date. Use a real date in YYYY-MM-DD format."))
    }

    private static func outOfRange() -> AnswerError {
        AnswerError(localized("The result must be between years 0001 and 9999."))
    }

    private static func dateSeconds(_ text: String) throws(AnswerError) -> Int64 {
        let parts = text.split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3, parts[0] >= 1, let date = CivilDate(year: parts[0], month: parts[1], day: parts[2])
        else { throw invalidDate() }
        return date.daysSinceEpoch * day
    }

    /// Floor division so instants before 1970 map to the right calendar day.
    private static func civil(_ seconds: Int64) -> (date: CivilDate, secondOfDay: Int64) {
        let days = seconds >= 0 ? seconds / day : (seconds - day + 1) / day
        return (CivilDate(daysSinceEpoch: days), seconds - days * day)
    }

    private static func isoDate(_ seconds: Int64) throws(AnswerError) -> String {
        let date = civil(seconds).date
        guard (1...9999).contains(date.year) else { throw outOfRange() }
        return date.iso
    }

    private static func addDays(_ date: String, _ amount: String, sign: Int64) throws(AnswerError) -> Result {
        let start = try dateSeconds(date)
        guard let days = Double(amount), days <= Double(maximumDays) else {
            throw AnswerError(localized("Use no more than 3,652,058 whole days."))
        }
        return Result(kind: .date, result: try isoDate(start + sign * Int64(days) * day),
                      context: localized("Calendar days · Calculated on this device"), summary: localized("Calendar days"))
    }

    private static func between(_ start: String, _ end: String) throws(AnswerError) -> Result {
        let days = (try dateSeconds(end) - (try dateSeconds(start))) / day
        return Result(kind: .difference, result: "\(days) days",
                      context: localized("\(start) → \(end) · End date minus start date"),
                      summary: localized("End date minus start date"))
    }

    // MARK: Time zones

    struct Zone: Sendable {
        /// Nil means UTC, which prints with a trailing `Z`.
        let timeZone: TimeZone?
        var name: String { timeZone?.identifier ?? "UTC" }

        func offset(at instant: Int64) -> Int64 {
            guard let timeZone else { return 0 }
            return Int64(timeZone.secondsFromGMT(for: Date(timeIntervalSince1970: TimeInterval(instant))))
        }
    }

    private static func resolveZone(_ text: String) throws(AnswerError) -> Zone {
        if utcName.matches(text) { return Zone(timeZone: nil) }
        let name = text == "서울" || text == "한국" ? "Asia/Seoul" : text
        // Abbreviations such as CST are ambiguous; accept UTC or explicit IANA paths.
        guard ianaName.matches(name) else {
            throw AnswerError(localized("Use UTC or an IANA time zone such as Asia/Seoul or America/New_York."))
        }
        let identifier = TimeZone.knownTimeZoneIdentifiers.first { $0.caseInsensitiveCompare(name) == .orderedSame } ?? name
        guard let zone = TimeZone(identifier: identifier) else {
            throw AnswerError(localized("Unknown time zone. Use an IANA name such as Asia/Seoul."))
        }
        return Zone(timeZone: zone)
    }

    private static func offsetMinutes(_ text: String) throws(AnswerError) -> Int {
        if text.lowercased() == "z" { return 0 }
        let characters = Array(text)
        let hours = Int(String(characters[1...2]))!
        let minutes = Int(String(characters[4...5]))!
        if hours > 23 || minutes > 59 {
            throw AnswerError(localized("Invalid UTC offset. Use ±HH:mm with hours below 24 and minutes below 60."))
        }
        return (hours * 60 + minutes) * (characters[0] == "-" ? -1 : 1)
    }

    private static func mismatch() -> AnswerError {
        AnswerError(localized("The UTC offset does not match the source time zone at that local time."))
    }

    private static func localInstant(wall: Int64, zone: Zone, explicitOffset: String?) throws(AnswerError) -> Int64 {
        guard zone.timeZone != nil else {
            if let explicitOffset, try offsetMinutes(explicitOffset) != 0 { throw mismatch() }
            return wall
        }
        if let explicitOffset {
            let instant = wall - Int64(try offsetMinutes(explicitOffset)) * 60
            guard instant + zone.offset(at: instant) == wall else { throw mismatch() }
            return instant
        }
        // Modern IANA offsets are whole minutes. Historical local-mean-time offsets can contain seconds,
        // so those dates need an exact input.
        if civil(wall).date.year < 1973 {
            throw AnswerError(localized("For time-zone dates before 1973, provide an explicit UTC offset or a UTC time."))
        }
        // Try every whole-minute offset instead of assuming a one-hour DST shift, which also catches
        // half-hour transitions and skipped calendar days.
        var matches: [Int64] = []
        for offset in Int64(-24 * 60)...Int64(24 * 60) {
            let candidate = wall - offset * 60
            guard candidate + zone.offset(at: candidate) == wall else { continue }
            matches.append(candidate)
            if matches.count > 1 {
                throw AnswerError(localized("This local time occurs twice because the time-zone offset changes. Add an explicit offset, such as -04:00 or -05:00, to choose the intended time."))
            }
        }
        guard let instant = matches.first else {
            throw AnswerError(localized("This local time does not exist because the time-zone offset changes. Choose a valid local time or provide an exact UTC time."))
        }
        return instant
    }

    private static func zoneResult(_ instant: Int64, zone: Zone) throws(AnswerError) -> String {
        _ = try isoDate(instant)
        if zone.timeZone == nil { return timestamp(instant) + "Z" }
        let offset = zone.offset(at: instant)
        let wall = instant + offset
        _ = try isoDate(wall)
        let absolute = abs(offset)
        var suffix = (offset < 0 ? "-" : "+") + two(absolute / 3600) + ":" + two(absolute % 3600 / 60)
        if absolute % 60 != 0 { suffix += ":" + two(absolute % 60) }
        return timestamp(wall) + suffix + "[\(zone.name)]"
    }

    private static func timestamp(_ seconds: Int64) -> String {
        let (date, second) = civil(seconds)
        return date.iso + "T" + two(second / 3600) + ":" + two(second % 3600 / 60) + ":" + two(second % 60)
    }

    private static func two(_ value: Int64) -> String {
        value < 10 ? "0\(value)" : "\(value)"
    }
}
