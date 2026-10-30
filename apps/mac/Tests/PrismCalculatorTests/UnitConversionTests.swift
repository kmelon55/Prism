import Testing
@testable import PrismCalculator

// Ported from apps/desktop/src/providers/units.test.ts.

@Test(arguments: [
    ("10 cm to inch", "3.93700787402", "in"), ("1 inch to cm", "2.54", "cm"),
    ("1마일 킬로미터", "1.609344", "km"), ("1,000 m to km", "1", "km"),
    ("1000미터 킬로미터로", "1", "km"), ("2.5 kg to g", "2500", "g"),
    ("1 lb to kg", "0.45359237", "kg"), ("1 oz to g", "28.349523125", "g"),
    ("32 F to C", "0", "°C"), ("100 섭씨 화씨", "212", "°F"),
    ("-40 °C to °F", "-40", "°F"), ("-273.15 C to K", "0", "K"),
    ("0 K to C", "-273.15", "°C"), ("-459.67 F to K", "0", "K"),
    ("2 L to ml", "2000", "mL"), ("1 m3 to L", "1000", "L"),
    ("2시간 분", "120", "min"), ("1 d to h", "24", "h"), (".5 h to min", "30", "min"),
    ("1 m2 to cm2", "10000", "cm²"), ("1 ft2 to m2", "0.09290304", "m²"),
    ("1 GB to MB", "1000", "MB"), ("1 GiB to MiB", "1024", "MiB"),
    ("1 GB to MiB", "953.674316406", "MiB"), ("8 Mb to MB", "1", "MB"),
    ("1 B to b", "8", "b"), ("1,234.56789 m to m", "1234.56789", "m"),
    ("3 Feet IN Meters", "0.9144", "m"), ("1 km → mi", "0.621371192237", "mi"),
])
func convertsUnits(query: String, expected: String, label: String) throws {
    let conversion = try #require(try UnitConversion.convert(query))
    #expect(conversion.result == expected)
    #expect(conversion.to.label == label)
}

@Test(arguments: [
    "paper", "100", "100달러", "100 USD to KRW", "1,00 m to km", "1e3 m to km", "1 mb to MB",
    "1 m/s to km/h", "1 gallon to L", "10 m to cm\n", "m to cm", "10 m",
])
func doesNotGuessUnsupportedSyntax(query: String) throws {
    #expect(try UnitConversion.convert(query) == nil)
}

@Test func reportsIncompatibleDimensionsAndImpossibleTemperatures() {
    func message(_ query: String) -> String? {
        do { _ = try UnitConversion.convert(query); return nil } catch { return error.message }
    }
    #expect(message("1 kg to cm")?.contains("same kind") == true)
    #expect(message("-1 K to C")?.contains("absolute zero") == true)
    #expect(message("-274 C to F")?.contains("absolute zero") == true)
    #expect(message("-0.000000000001 K to C")?.contains("absolute zero") == true)
    #expect(message("1000000000001 m to cm")?.contains("no larger") == true)
}

@Test func returnsAQueryCorrelatedAnswerWithAPlainCopyValue() throws {
    let answer = try #require(InstantAnswers.unit("1 GB to B"))
    #expect(answer.title == "1,000,000,000 B")
    #expect(answer.subtitle == "1 GB")
    #expect(answer.copyValue == "1000000000")
    #expect(answer.formattedValue == "1,000,000,000")
    #expect(answer.equation == "1 GB = 1,000,000,000 B")
    #expect(answer.matchedQuery == "1 GB to B")
    #expect(answer.id == "units:result")

    let failure = try #require(InstantAnswers.unit("1 kg to cm"))
    #expect(failure.kind == .failure)
    #expect(failure.matchedQuery == "1 kg to cm")
}
