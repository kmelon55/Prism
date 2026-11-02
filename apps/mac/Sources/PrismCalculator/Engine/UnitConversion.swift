import Foundation

/// Local unit conversion. Recognizes `<amount> <unit> to <unit>`, the Korean `<amount><unit> <unit>(으)로` form,
/// and a bare `<amount><unit>` such as `180cm` or `30평`, which converts to the units people usually want next.
enum UnitConversion {
    enum Family: String, Sendable {
        case length = "Length", mass = "Mass", temperature = "Temperature", volume = "Volume"
        case duration = "Duration", area = "Area", dataSize = "Data size", speed = "Speed"

        var localizedName: String {
            switch self {
            case .length: localized("Length")
            case .mass: localized("Mass")
            case .temperature: localized("Temperature")
            case .volume: localized("Volume")
            case .duration: localized("Duration")
            case .area: localized("Area")
            case .dataSize: localized("Data size")
            case .speed: localized("Speed")
            }
        }

        /// Families a bare `<amount><unit>` answers. Durations and data sizes need `to`, since `3d` or `5b`
        /// are more often searches than conversions.
        var answersBareAmount: Bool { self != .duration && self != .dataSize }
    }

    struct Unit: Equatable, Sendable {
        let family: Family
        let label: String
        let scale: Double
        let offset: Double
        /// English name, also the localization key.
        let name: String

        var localizedName: String { name.isEmpty ? label : localized(String.LocalizationValue(name)) }
    }

    struct Result: Equatable, Sendable {
        /// The amount as typed, without grouping.
        let amount: String
        let from: Unit
        let to: Unit
        /// The converted value as plain text; also the copy value.
        let result: String
        /// The amount in the family's base unit (meters, kilograms, kelvin, ...).
        var base: Double = 0
    }

    private static let units: [String: Unit] = {
        var table: [String: Unit] = [:]
        func define(_ family: Family, _ label: String, _ scale: Double, _ aliases: [String], offset: Double = 0, name: String = "") {
            let unit = Unit(family: family, label: label, scale: scale, offset: offset, name: name)
            for alias in [label] + aliases { table[alias] = unit }
        }
        define(.length, "mm", 0.001, ["millimeter", "millimeters", "밀리미터", "미리"], name: "Millimeters")
        define(.length, "cm", 0.01, ["centimeter", "centimeters", "센티미터", "센티", "센치"], name: "Centimeters")
        define(.length, "m", 1, ["meter", "meters", "미터"], name: "Meters")
        define(.length, "km", 1000, ["kilometer", "kilometers", "킬로미터", "키로"], name: "Kilometers")
        define(.length, "in", 0.0254, ["inch", "inches", "인치", "\""], name: "Inches")
        define(.length, "ft", 0.3048, ["foot", "feet", "피트", "'"], name: "Feet")
        define(.length, "yd", 0.9144, ["yard", "yards", "야드"], name: "Yards")
        define(.length, "mi", 1609.344, ["mile", "miles", "마일"], name: "Miles")
        define(.length, "nmi", 1852, ["nautical mile", "nautical miles", "해리"], name: "Nautical miles")
        define(.mass, "mg", 0.000001, ["milligram", "milligrams", "밀리그램"], name: "Milligrams")
        define(.mass, "g", 0.001, ["gram", "grams", "그램"], name: "Grams")
        define(.mass, "kg", 1, ["kilogram", "kilograms", "킬로그램", "킬로"], name: "Kilograms")
        define(.mass, "t", 1000, ["tonne", "tonnes", "metric ton", "톤"], name: "Tonnes")
        define(.mass, "oz", 0.028349523125, ["ounce", "ounces", "온스"], name: "Ounces")
        define(.mass, "lb", 0.45359237, ["lbs", "pound", "pounds", "파운드"], name: "Pounds")
        define(.mass, "st", 6.35029318, ["stone", "stones", "스톤"], name: "Stones")
        define(.mass, "근", 0.6, [], name: "Geun (600 g)")
        define(.mass, "돈", 0.00375, [], name: "Don (3.75 g)")
        define(.temperature, "°C", 1, ["C", "℃", "celsius", "섭씨", "도"], offset: 273.15, name: "Celsius")
        define(.temperature, "°F", 5.0 / 9.0, ["F", "℉", "fahrenheit", "화씨"], offset: 273.15 - 32.0 * 5.0 / 9.0, name: "Fahrenheit")
        define(.temperature, "K", 1, ["kelvin", "켈빈"], name: "Kelvin")
        define(.volume, "mL", 0.001, ["ml", "cc", "milliliter", "milliliters", "밀리리터"], name: "Milliliters")
        define(.volume, "L", 1, ["l", "liter", "liters", "litre", "litres", "리터"], name: "Liters")
        define(.volume, "m³", 1000, ["m3", "cubic meter", "cubic meters", "세제곱미터"], name: "Cubic meters")
        define(.volume, "tsp", 0.00492892159375, ["teaspoon", "teaspoons", "티스푼", "작은술"], name: "Teaspoons")
        define(.volume, "tbsp", 0.01478676478125, ["tablespoon", "tablespoons", "테이블스푼", "큰술"], name: "Tablespoons")
        define(.volume, "fl oz", 0.0295735295625, ["floz", "fluid ounce", "fluid ounces", "액량온스"], name: "Fluid ounces")
        define(.volume, "cup", 0.2365882365, ["cups", "컵"], name: "Cups (US)")
        define(.volume, "pt", 0.473176473, ["pint", "pints", "파인트"], name: "Pints (US)")
        define(.volume, "qt", 0.946352946, ["quart", "quarts", "쿼트"], name: "Quarts (US)")
        define(.volume, "gal", 3.785411784, ["gallon", "gallons", "갤런"], name: "Gallons (US)")
        define(.duration, "ms", 0.001, ["millisecond", "milliseconds", "밀리초"], name: "Milliseconds")
        define(.duration, "s", 1, ["sec", "second", "seconds", "초"], name: "Seconds")
        define(.duration, "min", 60, ["minute", "minutes", "분"], name: "Minutes")
        define(.duration, "h", 3600, ["hr", "hour", "hours", "시간"], name: "Hours")
        define(.duration, "d", 86400, ["day", "days", "일"], name: "Days")
        define(.duration, "wk", 604800, ["week", "weeks", "주"], name: "Weeks")
        define(.area, "cm²", 0.0001, ["cm2", "제곱센티미터"], name: "Square centimeters")
        define(.area, "m²", 1, ["m2", "sqm", "제곱미터", "㎡"], name: "Square meters")
        define(.area, "km²", 1000000, ["km2", "제곱킬로미터"], name: "Square kilometers")
        define(.area, "ft²", 0.09290304, ["ft2", "sqft", "제곱피트"], name: "Square feet")
        define(.area, "ha", 10000, ["hectare", "hectares", "헥타르"], name: "Hectares")
        define(.area, "ac", 4046.8564224, ["acre", "acres", "에이커"], name: "Acres")
        define(.area, "평", 400.0 / 121.0, ["pyeong"], name: "Pyeong")
        define(.speed, "m/s", 1, ["mps", "초속"], name: "Meters per second")
        define(.speed, "km/h", 1.0 / 3.6, ["kph", "kmh", "km/hr", "시속"], name: "Kilometers per hour")
        define(.speed, "mph", 0.44704, ["mi/h", "miles per hour"], name: "Miles per hour")
        define(.speed, "kn", 0.514444444444, ["knot", "knots", "노트"], name: "Knots")
        define(.dataSize, "B", 1, ["byte", "bytes", "바이트"], name: "Bytes")
        define(.dataSize, "b", 1.0 / 8.0, ["bit", "bits", "비트"], name: "Bits")
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

    /// What a conversion from each unit usually wants next. The first is the bare amount's main answer.
    private static let related: [String: [String]] = [
        "mm": ["cm", "in", "m"], "cm": ["ft", "in", "m", "mm"], "m": ["ft", "yd", "cm", "km", "in"],
        "km": ["mi", "m", "ft", "nmi"], "in": ["cm", "mm", "ft"], "ft": ["m", "cm", "in", "yd"],
        "yd": ["m", "ft", "cm"], "mi": ["km", "m", "ft"], "nmi": ["km", "mi"],
        "mg": ["g", "oz"], "g": ["oz", "kg", "lb", "돈"], "kg": ["lb", "g", "oz", "근", "st"],
        "t": ["kg", "lb"], "oz": ["g", "lb", "kg"], "lb": ["kg", "g", "oz", "st"], "st": ["kg", "lb"],
        "근": ["kg", "g", "lb"], "돈": ["g", "oz"],
        "°C": ["°F", "K"], "°F": ["°C", "K"], "K": ["°C", "°F"],
        "mL": ["fl oz", "cup", "tbsp", "tsp", "L"], "L": ["gal", "mL", "cup", "fl oz", "qt"], "m³": ["L", "gal"],
        "tsp": ["mL", "tbsp"], "tbsp": ["mL", "tsp", "cup"], "fl oz": ["mL", "cup", "L"],
        "cup": ["mL", "fl oz", "tbsp", "L"], "pt": ["mL", "L", "cup"], "qt": ["L", "mL", "gal"], "gal": ["L", "mL", "qt"],
        "cm²": ["m²", "ft²"], "m²": ["평", "ft²", "cm²"], "평": ["m²", "ft²"], "ft²": ["m²", "평"],
        "km²": ["m²", "ha", "ac"], "ha": ["m²", "ac", "평"], "ac": ["m²", "ha", "평"],
        "m/s": ["km/h", "mph", "kn"], "km/h": ["mph", "m/s", "kn"], "mph": ["km/h", "m/s", "kn"], "kn": ["km/h", "mph", "m/s"],
        "ms": ["s"], "s": ["min", "ms"], "min": ["s", "h"], "h": ["min", "s", "d"], "d": ["h", "wk", "min"], "wk": ["d", "h"],
        "kB": ["B", "MB", "KiB"], "MB": ["kB", "GB", "MiB"], "GB": ["MB", "TB", "GiB"], "TB": ["GB", "TiB"],
        "KiB": ["kB", "MiB"], "MiB": ["MB", "KiB", "GiB"], "GiB": ["GB", "MiB", "TiB"], "TiB": ["TB", "GiB"],
    ]

    /// Full English names may ignore case; symbols deliberately preserve it (MB is not Mb).
    private static func resolve(_ text: String) -> Unit? {
        units[text] ?? (text.utf16.count > 3 ? units[text.lowercased()] : nil)
    }

    private static let amount = #"[+-]?(?:(?:[0-9]{1,3}(?:,[0-9]{3})+|[0-9]+)(?:\.[0-9]{1,12})?|\.[0-9]{1,12})"#
    private static let query = Pattern(#"^("# + amount + #")\s*(.+?)\s+(?:to|in|->|→|=)\s*(.+)$"#, caseInsensitive: true)
    private static let korean = Pattern(#"^("# + amount + #")\s*(.+?)\s+(.+?)(?:으로|로)?$"#)
    private static let bare = Pattern(#"^("# + amount + #")\s*([^\s0-9].*?)$"#)

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
        return try convert(amount: amount, from: from, to: to)
    }

    /// The requested conversion first, then related units; a bare `180cm` leads with its most useful unit.
    /// Nil when the text is not a conversion.
    static func conversions(_ text: String, limit: Int = 6) throws(AnswerError) -> [Result]? {
        if let primary = try convert(text) {
            let rest = (related[primary.from.label] ?? []).filter { $0 != primary.to.label && $0 != primary.from.label }
            var results = [primary]
            for label in rest.prefix(limit) {
                if let unit = units[label] { results.append(try convert(amount: primary.amount, from: primary.from, to: unit)) }
            }
            return results
        }
        if text.utf16.count > 40 || text.containsControlCharacter { return nil }
        guard let match = bare.match(text.jsTrimmed), let amountText = match[1], let fromText = match[2],
              let amount = NumberFormat.ungroupDecimal(amountText),
              let from = resolve(fromText.jsTrimmed), from.family.answersBareAmount,
              let targets = related[from.label], !targets.isEmpty
        else { return nil }
        var results: [Result] = []
        for label in targets.prefix(limit + 1) {
            if let unit = units[label] { results.append(try convert(amount: amount, from: from, to: unit)) }
        }
        return results
    }

    static func convert(amount: String, from: Unit, to: Unit) throws(AnswerError) -> Result {
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
        return Result(amount: amount, from: from, to: to, result: result == "-0" ? "0" : result, base: base)
    }

    /// A length as whole feet and inches to one decimal, such as 5 ft 10.9 in, for heights between 1 and 10 feet.
    static func feetAndInches(meters: Double) -> (feet: Int, inches: Double)? {
        let total = meters / 0.0254
        guard total >= 12, total < 120 else { return nil }
        var feet = Int(total / 12)
        var inches = ((total - Double(feet) * 12) * 10).rounded() / 10
        if inches >= 12 { feet += 1; inches = 0 }
        return (feet, inches)
    }
}
