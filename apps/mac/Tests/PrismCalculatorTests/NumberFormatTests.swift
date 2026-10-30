import Testing
@testable import PrismCalculator

// Ported from apps/desktop/src/providers/number-format.test.ts.

@Test(arguments: [
    ("123456789012345678.123456789", "123,456,789,012,345,678.123456789"),
    ("-1234567.000100", "-1,234,567.000100"), ("0.000000000001", "0.000000000001"),
    ("1.25e+30", "1.25e+30"), ("1000", "1,000"), ("not a number", "not a number"),
])
func groupingPreservesAllDigits(value: String, expected: String) {
    #expect(NumberFormat.groupDecimal(value) == expected)
}

@Test func removesOnlyWellFormedGroupingInArithmeticLiterals() {
    #expect(NumberFormat.normalizeArithmeticExpression("(1,000.25 + 20,000) / .5") == "(1000.25 + 20000) / .5")
    for invalid in ["1,00+2", "12,34,567+1", "1.2,3+1", "1,,000+1", "1,000,+2"] {
        #expect(NumberFormat.normalizeArithmeticExpression(invalid) == nil, "\(invalid)")
    }
}

@Test func groupsDisplayValuesWhileCopyingUntouchedResults() throws {
    let answer = try #require(InstantAnswers.calculation("1,000 + 2,000"))
    #expect(answer.title == "3,000")
    #expect(answer.subtitle == "1,000 + 2,000")
    #expect(answer.copyValue == "3000")
    #expect(answer.formattedValue == "3,000")
    #expect(answer.equation == "1,000 + 2,000 = 3,000")
    #expect(answer.matchedQuery == "1,000 + 2,000")
    #expect(InstantAnswers.calculation("1,00+2") == nil)

    let long = try #require(InstantAnswers.calculation("1234567.890123 * 1"))
    #expect(long.title == "1,234,567.890123")
    #expect(long.copyValue == "1234567.890123")
}

@Test func calculatorIgnoresPlainWordsAndNumbers() {
    for query in ["", "   ", "paper", "42", "1,000", "safari", "2 + x", "(1)", "100 USD to KRW"] {
        #expect(InstantAnswers.calculation(query) == nil, "\(query)")
    }
    #expect(InstantAnswers.calculation(" 2 + 2 ")?.matchedQuery == "2 + 2")
}

@Test func runtimeNumberTextMatchesJavaScriptAndRust() {
    #expect(NumberFormat.javaScriptString(1e21) == "1e+21")
    #expect(NumberFormat.javaScriptString(1e20) == "100000000000000000000")
    #expect(NumberFormat.javaScriptString(1e-7) == "1e-7")
    #expect(NumberFormat.javaScriptString(0.000001) == "0.000001")
    #expect(NumberFormat.javaScriptString(-1.5e-10) == "-1.5e-10")
    #expect(NumberFormat.javaScriptString(123.456) == "123.456")
    #expect(NumberFormat.rustDisplay(1e21) == "1000000000000000000000")
    #expect(NumberFormat.rustDisplay(1e-7) == "0.0000001")
    #expect(NumberFormat.rustDisplay(-0.0) == "-0")
    #expect(NumberFormat.javaScriptFixed(0.125, digits: 2) == "0.13")
    #expect(NumberFormat.javaScriptFixed(1.005, digits: 2) == "1.00")
    #expect(NumberFormat.javaScriptFixed(-0.001, digits: 2) == "-0.00")
    #expect(NumberFormat.javaScriptFixed(128000, digits: 0) == "128000")
    #expect(NumberFormat.javaScriptFixed(2.5, digits: 0) == "3")
    #expect(NumberFormat.label(0.000_000_4) == "0")
    #expect(NumberFormat.label(1234.5) == "1,234.5")
    #expect(NumberFormat.label(0.000625) == "0.000625")
}
