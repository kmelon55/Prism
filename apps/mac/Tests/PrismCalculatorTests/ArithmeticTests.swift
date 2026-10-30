import Testing
@testable import PrismCalculator

// Ported from apps/desktop/src-tauri/src/arithmetic.rs.

private func evaluates(_ expression: String, _ expected: String) {
    #expect((try? Arithmetic.evaluate(expression)) == expected, "\(expression)")
}

private func rejects(_ expression: String, _ expected: Arithmetic.Failure) {
    #expect(throws: expected, "\(expression)") { try Arithmetic.evaluate(expression) }
}

@Test func appliesPrecedenceParenthesesAndLeftAssociativity() {
    evaluates("2 + 3 * 4", "14")
    evaluates("(2 + 3) * 4", "20")
    evaluates("8 / 4 / 2", "1")
    evaluates("5 - 2 - 1", "2")
    evaluates("2 * (3 + (4 - 1))", "12")
}

@Test func acceptsDecimalLiteralsAndUnicodeWhitespace() {
    evaluates(".5 + 1.5", "2")
    evaluates("1. + .25", "1.25")
    evaluates("\u{2003}2.5\u{00a0}*\t4\n", "10")
}

@Test func appliesUnaryOperatorsInEveryOperandPosition() {
    evaluates("-2 * -(3 + +1)", "8")
    evaluates("1--2", "3")
    evaluates("1+-2", "-1")
    evaluates("+2 * +3", "6")
}

@Test func rejectsNumbersWithoutABinaryOperation() {
    rejects("42", .plainNumber)
    rejects("-42", .plainNumber)
    rejects("(((+42)))", .plainNumber)
}

@Test func rejectsEmptyUnknownAndMalformedExpressions() {
    rejects("", .empty)
    rejects(" \t\n", .empty)
    rejects("1 + answer", .invalidCharacter)
    rejects("1 ^ 2", .invalidCharacter)
    rejects("1e2 + 1", .invalidCharacter)
    rejects(".", .invalidNumber)
    rejects("1 +", .unexpectedToken)
    rejects("()", .unexpectedToken)
    rejects("2(3 + 4)", .unexpectedToken)
    rejects("(1 + 2", .unexpectedToken)
    rejects("1 + 2)", .unexpectedToken)
    rejects("1..2 + 3", .unexpectedToken)
}

@Test func rejectsDivisionByPositiveNegativeAndComputedZero() {
    rejects("1 / 0", .divisionByZero)
    rejects("1 / -0", .divisionByZero)
    rejects("1 / (2 - 2)", .divisionByZero)
}

@Test func rejectsNonFiniteArithmeticValues() {
    #expect(throws: Arithmetic.Failure.nonFinite) { try Arithmetic.finite(.infinity) }
    #expect(throws: Arithmetic.Failure.nonFinite) { try Arithmetic.finite(-.infinity) }
    #expect(throws: Arithmetic.Failure.nonFinite) { try Arithmetic.finite(.nan) }
    #expect(throws: Arithmetic.Failure.nonFinite) { try Arithmetic.format(.infinity) }
}

@Test func enforcesExpressionLengthWithoutPenalizingTheBoundary() {
    let accepted = String(repeating: " ", count: Arithmetic.maxExpressionBytes - 3) + "1+1"
    evaluates(accepted, "2")
    rejects(accepted + " ", .tooLong)
    rejects(String(repeating: " ", count: Arithmetic.maxExpressionBytes + 1), .tooLong)
}

@Test func enforcesTokenLimitWithoutAnOffByOneError() {
    evaluates(Array(repeating: "1", count: 64).joined(separator: "+"), "64")
    rejects(Array(repeating: "1", count: 65).joined(separator: "+"), .tooManyTokens)
}

@Test func enforcesParenthesisAndUnaryNestingLimits() {
    let depth = Arithmetic.maxNesting
    evaluates(String(repeating: "(", count: depth) + "1+1" + String(repeating: ")", count: depth), "2")
    rejects(String(repeating: "(", count: depth + 1) + "1+1" + String(repeating: ")", count: depth + 1), .tooDeep)
    evaluates(String(repeating: "+", count: depth) + "1+1", "2")
    rejects(String(repeating: "+", count: depth + 1) + "1+1", .tooDeep)
}

@Test func returnsOnlyPlainCopySafeFiniteText() throws {
    evaluates("1 * -0", "0")
    evaluates("1 / 10000000000", "0.0000000001")
    for expression in ["1 / 3", String(repeating: "9", count: 125) + "+1"] {
        let result = try Arithmetic.evaluate(expression)
        #expect(result.count <= 32)
        let hasWhitespace = result.contains { $0.isWhitespace }
        #expect(!hasWhitespace)
        #expect(result.allSatisfy { $0.isASCII && ($0.isNumber || "+-.e".contains($0)) })
    }
    #expect(try Arithmetic.evaluate("1 / 3") == "0.3333333333333333")
    #expect(try Arithmetic.evaluate(String(repeating: "9", count: 125) + "+1") == "9.999999999999999e124")
    #expect(try Arithmetic.evaluate("0.1 + 0.2") == "0.30000000000000004")
    #expect(try Arithmetic.evaluate("123456789 * 1000000000000") == "123456789000000000000")
}

@Test func commandMapsEveryRejectionToNoPaletteResult() {
    #expect(InstantAnswers.calculation("3 * 7")?.copyValue == "21")
    #expect(InstantAnswers.calculation("21") == nil)
    #expect(InstantAnswers.calculation("1 / 0") == nil)
}
