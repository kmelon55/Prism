import Foundation

/// The bounded arithmetic evaluator from `arithmetic.rs`: `+ - * /`, parentheses and unary signs over
/// decimal literals. Anything else, including a bare number, is rejected so plain words never get an answer.
enum Arithmetic {
    static let maxExpressionBytes = 256
    static let maxTokens = 128
    static let maxNesting = 32

    enum Failure: Error, Equatable {
        case empty, tooLong, tooManyTokens, tooDeep, invalidCharacter, invalidNumber
        case unexpectedToken, divisionByZero, nonFinite, plainNumber
    }

    private enum Token: Equatable {
        case number(Double)
        case plus, minus, multiply, divide, open, close
    }

    static func evaluate(_ expression: String) throws(Failure) -> String {
        if expression.isEmpty { throw .empty }
        if expression.utf8.count > maxExpressionBytes { throw .tooLong }
        let tokens = try tokenize(expression)
        if tokens.isEmpty { throw .empty }
        var parser = Parser(tokens: tokens)
        return try format(parser.parse())
    }

    private static func tokenize(_ expression: String) throws(Failure) -> [Token] {
        let scalars = Array(expression.unicodeScalars)
        var tokens: [Token] = []
        var cursor = 0
        while cursor < scalars.count {
            let scalar = scalars[cursor]
            if scalar.properties.isWhitespace {
                cursor += 1
                continue
            }
            let token: Token
            switch scalar {
            case "+": token = .plus; cursor += 1
            case "-": token = .minus; cursor += 1
            case "*": token = .multiply; cursor += 1
            case "/": token = .divide; cursor += 1
            case "(": token = .open; cursor += 1
            case ")": token = .close; cursor += 1
            case "0"..."9", ".":
                var literal = ""
                var sawDigit = false
                var sawPoint = false
                while cursor < scalars.count {
                    let next = scalars[cursor]
                    if ("0"..."9").contains(next) {
                        sawDigit = true
                    } else if next == ".", !sawPoint {
                        sawPoint = true
                    } else {
                        break
                    }
                    literal.unicodeScalars.append(next)
                    cursor += 1
                }
                guard sawDigit else { throw .invalidNumber }
                // Rust accepts `1.` and `.5`; normalize them before handing the literal to strtod.
                if literal.hasPrefix(".") { literal = "0" + literal }
                if literal.hasSuffix(".") { literal += "0" }
                guard let value = Double(literal), value.isFinite else { throw .nonFinite }
                token = .number(value)
            default:
                throw .invalidCharacter
            }
            tokens.append(token)
            if tokens.count > maxTokens { throw .tooManyTokens }
        }
        return tokens
    }

    private struct Parser {
        let tokens: [Token]
        var cursor = 0
        var sawBinaryOperator = false

        init(tokens: [Token]) {
            self.tokens = tokens
        }

        private var current: Token? { tokens.indices.contains(cursor) ? tokens[cursor] : nil }

        mutating func parse() throws(Failure) -> Double {
            let result = try parseSum(depth: 0)
            if cursor != tokens.count { throw .unexpectedToken }
            if !sawBinaryOperator { throw .plainNumber }
            return try finite(result)
        }

        private mutating func parseSum(depth: Int) throws(Failure) -> Double {
            var result = try parseProduct(depth: depth)
            while let operation = current, operation == .plus || operation == .minus {
                cursor += 1
                sawBinaryOperator = true
                let right = try parseProduct(depth: depth)
                result = try finite(operation == .plus ? result + right : result - right)
            }
            return result
        }

        private mutating func parseProduct(depth: Int) throws(Failure) -> Double {
            var result = try parseUnary(depth: depth)
            while let operation = current, operation == .multiply || operation == .divide {
                cursor += 1
                sawBinaryOperator = true
                let right = try parseUnary(depth: depth)
                if operation == .divide, right == 0 { throw .divisionByZero }
                result = try finite(operation == .multiply ? result * right : result / right)
            }
            return result
        }

        private mutating func parseUnary(depth: Int) throws(Failure) -> Double {
            guard let sign = current, sign == .plus || sign == .minus else { return try parsePrimary(depth: depth) }
            if depth >= Arithmetic.maxNesting { throw .tooDeep }
            cursor += 1
            let value = try parseUnary(depth: depth + 1)
            return try finite(sign == .minus ? -value : value)
        }

        private mutating func parsePrimary(depth: Int) throws(Failure) -> Double {
            switch current {
            case .number(let value)?:
                cursor += 1
                return value
            case .open?:
                if depth >= Arithmetic.maxNesting { throw .tooDeep }
                cursor += 1
                let value = try parseSum(depth: depth + 1)
                guard current == .close else { throw .unexpectedToken }
                cursor += 1
                return value
            default:
                throw .unexpectedToken
            }
        }
    }

    static func finite(_ value: Double) throws(Failure) -> Double {
        guard value.isFinite else { throw .nonFinite }
        return value
    }

    /// Plain, copy-safe text: positional when it fits in 32 characters, otherwise `1.2345e126`.
    static func format(_ value: Double) throws(Failure) -> String {
        guard value.isFinite else { throw .nonFinite }
        let value = value == 0 ? 0 : value
        var result = NumberFormat.rustDisplay(value)
        if result.count > 32 {
            let scientific = String(format: "%.15e", value)
            let parts = scientific.split(separator: "e", maxSplits: 1)
            guard parts.count == 2, let exponent = Int(parts[1]) else { throw .nonFinite }
            var mantissa = String(parts[0])
            while mantissa.hasSuffix("0") { mantissa.removeLast() }
            if mantissa.hasSuffix(".") { mantissa.removeLast() }
            result = "\(mantissa)e\(exponent)"
        }
        let copySafe = !result.isEmpty && result.count <= 32
            && result.allSatisfy { $0.isASCII && ($0.isNumber || "+-.e".contains($0)) }
        guard copySafe else { throw .nonFinite }
        return result
    }
}
