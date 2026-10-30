import Foundation

/// Local unit conversion from `units.ts`. Recognizes only `<amount> <unit> to <unit>` and the Korean
/// `<amount><unit> <unit>(으)로` form, with units of one family.
enum UnitConversion {
    enum Family: String, Sendable {
        case length = "Length", mass = "Mass", temperature = "Temperature", volume = "Volume"
        case duration = "Duration", area = "Area", dataSize = "Data size"

        var localizedName: String {
            switch self {
            case .length: localized("Length")
            case .mass: localized("Mass")
            case .temperature: localized("Temperature")
            case .volume: localized("Volume")
            case .duration: localized("Duration")
            case .area: localized("Area")
            case .dataSize: localized("Data size")
            }
        }
    }

    struct Unit: Equatable, Sendable {
        let family: Family
        let label: String
        let scale: Double
        let offset: Double
    }

    struct Result: Equatable, Sendable {
        /// The amount as typed, without grouping.
        let amount: String
        let from: Unit
        let to: Unit
        /// The converted value as plain text; also the copy value.
        let result: String
    }

    private static let units: [String: Unit] = {
        var table: [String: Unit] = [:]
        func define(_ family: Family, _ label: String, _ scale: Double, _ aliases: [String], offset: Double = 0) {
            let unit = Unit(family: family, label: label, scale: scale, offset: offset)
            for alias in [label] + aliases { table[alias] = unit }
        }
        define(.length, "mm", 0.001, ["millimeter", "millimeters", "밀리미터"])
        define(.length, "cm", 0.01, ["centimeter", "centimeters", "센티미터"])
        define(.length, "m", 1, ["meter", "meters", "미터"])
        define(.length, "km", 1000, ["kilometer", "kilometers", "킬로미터"])
        define(.length, "in", 0.0254, ["inch", "inches", "인치"])
        define(.length, "ft", 0.3048, ["foot", "feet", "피트"])
        define(.length, "yd", 0.9144, ["yard", "yards", "야드"])
        define(.length, "mi", 1609.344, ["mile", "miles", "마일"])
        define(.mass, "mg", 0.000001, ["milligram", "milligrams", "밀리그램"])
        define(.mass, "g", 0.001, ["gram", "grams", "그램"])
        define(.mass, "kg", 1, ["kilogram", "kilograms", "킬로그램"])
        define(.mass, "t", 1000, ["tonne", "tonnes", "metric ton", "톤"])
        define(.mass, "oz", 0.028349523125, ["ounce", "ounces", "온스"])
        define(.mass, "lb", 0.45359237, ["lbs", "pound", "pounds", "파운드"])
        define(.temperature, "°C", 1, ["C", "celsius", "섭씨"], offset: 273.15)
        define(.temperature, "°F", 5.0 / 9.0, ["F", "fahrenheit", "화씨"], offset: 273.15 - 32.0 * 5.0 / 9.0)
        define(.temperature, "K", 1, ["kelvin", "켈빈"])
        define(.volume, "mL", 0.001, ["ml", "milliliter", "milliliters", "밀리리터"])
        define(.volume, "L", 1, ["l", "liter", "liters", "litre", "litres", "리터"])
        define(.volume, "m³", 1000, ["m3", "cubic meter", "cubic meters", "세제곱미터"])
        define(.duration, "ms", 0.001, ["millisecond", "milliseconds", "밀리초"])
        define(.duration, "s", 1, ["sec", "second", "seconds", "초"])
        define(.duration, "min", 60, ["minute", "minutes", "분"])
        define(.duration, "h", 3600, ["hr", "hour", "hours", "시간"])
        define(.duration, "d", 86400, ["day", "days", "일"])
        define(.duration, "wk", 604800, ["week", "weeks", "주"])
        define(.area, "cm²", 0.0001, ["cm2", "제곱센티미터"])
        define(.area, "m²", 1, ["m2", "sqm", "제곱미터"])
        define(.area, "km²", 1000000, ["km2", "제곱킬로미터"])
        define(.area, "ft²", 0.09290304, ["ft2", "sqft", "제곱피트"])
        define(.area, "ha", 10000, ["hectare", "hectares", "헥타르"])
        define(.dataSize, "B", 1, ["byte", "bytes", "바이트"])
        define(.dataSize, "b", 1.0 / 8.0, ["bit", "bits", "비트"])
        for (prefix, power) in [("k", 1.0), ("M", 2), ("G", 3), ("T", 4)] {
            define(.dataSize, "\(prefix)B", pow(1000, power), prefix == "k" ? ["KB"] : [])
            define(.dataSize, "\(prefix)b", pow(1000, power) / 8, prefix == "k" ? ["Kb"] : [])
        }
        for (prefix, power) in [("Ki", 1.0), ("Mi", 2), ("Gi", 3), ("Ti", 4)] {
            define(.dataSize, "\(prefix)B", pow(1024, power), [])
            define(.dataSize, "\(prefix)b", pow(1024, power) / 8, [])
        }
        return table
    }()

    /// Full English names may ignore case; symbols deliberately preserve it (MB is not Mb).
    private static func resolve(_ text: String) -> Unit? {
        units[text] ?? (text.utf16.count > 3 ? units[text.lowercased()] : nil)
    }

    private static let amount = #"[+-]?(?:(?:[0-9]{1,3}(?:,[0-9]{3})+|[0-9]+)(?:\.[0-9]{1,12})?|\.[0-9]{1,12})"#
    private static let query = Pattern(#"^("# + amount + #")\s*(.+?)\s+(?:to|in|->|→|=)\s*(.+)$"#, caseInsensitive: true)
    private static let korean = Pattern(#"^("# + amount + #")\s*(.+?)\s+(.+?)(?:으로|로)?$"#)

    /// Returns nil for anything that is not a unit conversion, and throws for a recognized one that is invalid.
    static func convert(_ text: String) throws(AnswerError) -> Result? {
        if text.utf16.count > 160 || text.containsControlCharacter { return nil }
        let trimmed = text.jsTrimmed
        guard let match = query.match(trimmed) ?? korean.match(trimmed),
              let amountText = match[1], let fromText = match[2], let toText = match[3],
              let amount = NumberFormat.ungroupDecimal(amountText),
              let from = resolve(fromText.jsTrimmed), let to = resolve(toText.jsTrimmed)
        else { return nil }
        if from.family != to.family {
            throw AnswerError(localized("Cannot convert \(from.label) to \(to.label): choose units of the same kind."))
        }
        guard let numeric = Double(amount.hasPrefix(".") || amount.hasPrefix("-.") || amount.hasPrefix("+.")
            ? amount.replacingOccurrences(of: ".", with: "0.") : amount),
              numeric.isFinite, numeric.magnitude <= 1e12
        else { throw AnswerError(localized("Use an amount no larger than 1,000,000,000,000.")) }
        var base = numeric * from.scale + from.offset
        if from.family == .temperature {
            let minimum = from.label == "°C" ? -273.15 : from.label == "°F" ? -459.67 : 0
            if numeric < minimum { throw AnswerError(localized("Temperature cannot be below absolute zero.")) }
            base = max(0, base)
        }
        let result: String
        if from == to {
            result = NumberFormat.javaScriptString(numeric)
        } else {
            // Bound floating-point noise; the copy value is the same displayed number.
            let converted = (base - to.offset) / to.scale
            result = NumberFormat.javaScriptString(NumberFormat.rounded(converted, significantDigits: 12))
        }
        return Result(amount: amount, from: from, to: to, result: result == "-0" ? "0" : result)
    }
}
