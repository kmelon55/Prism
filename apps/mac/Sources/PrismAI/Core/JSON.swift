import Foundation

/// A dynamic JSON value. Provider requests and responses are reshaped field by field (tool loops append
/// provider-specific items), so they are handled as values rather than fixed Codable types, as the Rust host does.
public enum JSON: Sendable, Equatable {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case array([JSON])
    case object([String: JSON])

    public static func parse(_ data: Data) throws -> JSON {
        try JSON(any: JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]))
    }

    public static func parse(_ text: String) throws -> JSON {
        try parse(Data(text.utf8))
    }

    init(any value: Any) {
        switch value {
        case let number as NSNumber:
            if CFGetTypeID(number) == CFBooleanGetTypeID() { self = .bool(number.boolValue) } else { self = .number(number.doubleValue) }
        case let string as String: self = .string(string)
        case let array as [Any]: self = .array(array.map(JSON.init(any:)))
        case let object as [String: Any]: self = .object(object.mapValues(JSON.init(any:)))
        default: self = .null
        }
    }

    var anyValue: Any {
        switch self {
        case .null: NSNull()
        case .bool(let value): value
        case .number(let value):
            if value.rounded() == value, abs(value) < 9_007_199_254_740_992 { Int64(value) } else { value }
        case .string(let value): value
        case .array(let values): values.map(\.anyValue)
        case .object(let values): values.mapValues(\.anyValue)
        }
    }

    public func data() -> Data {
        (try? JSONSerialization.data(withJSONObject: anyValue, options: [.fragmentsAllowed, .sortedKeys, .withoutEscapingSlashes])) ?? Data("null".utf8)
    }

    public var text: String { String(decoding: data(), as: UTF8.self) }

    // MARK: Access

    public subscript(key: String) -> JSON {
        get { if case .object(let values) = self { values[key] ?? .null } else { .null } }
        set {
            var values: [String: JSON] = if case .object(let existing) = self { existing } else { [:] }
            values[key] = newValue
            self = .object(values)
        }
    }

    public subscript(index: Int) -> JSON {
        get { if case .array(let values) = self, values.indices.contains(index) { values[index] } else { .null } }
        set {
            guard case .array(var values) = self, values.indices.contains(index) else { return }
            values[index] = newValue
            self = .array(values)
        }
    }

    public var string: String? { if case .string(let value) = self { value } else { nil } }
    public var double: Double? { if case .number(let value) = self { value } else { nil } }
    public var bool: Bool? { if case .bool(let value) = self { value } else { nil } }
    public var array: [JSON]? { if case .array(let values) = self { values } else { nil } }
    public var object: [String: JSON]? { if case .object(let values) = self { values } else { nil } }
    public var isNull: Bool { self == .null }

    /// A non-negative integer, like serde's `as_u64`.
    public var uint: UInt64? {
        guard let value = double, value >= 0, value.rounded() == value, value < 1.8e19 else { return nil }
        return UInt64(value)
    }

    public mutating func append(_ value: JSON) {
        if case .array(var values) = self {
            values.append(value)
            self = .array(values)
        } else {
            self = .array([value])
        }
    }

    public var hasValue: Bool { !isNull }
}

extension JSON: ExpressibleByStringLiteral, ExpressibleByIntegerLiteral, ExpressibleByBooleanLiteral,
    ExpressibleByArrayLiteral, ExpressibleByDictionaryLiteral, ExpressibleByNilLiteral, ExpressibleByFloatLiteral {
    public init(stringLiteral value: String) { self = .string(value) }
    public init(integerLiteral value: Int) { self = .number(Double(value)) }
    public init(floatLiteral value: Double) { self = .number(value) }
    public init(booleanLiteral value: Bool) { self = .bool(value) }
    public init(arrayLiteral elements: JSON...) { self = .array(elements) }
    public init(dictionaryLiteral elements: (String, JSON)...) { self = .object(Dictionary(elements, uniquingKeysWith: { $1 })) }
    public init(nilLiteral: ()) { self = .null }
}

extension JSON {
    init(_ value: String?) { self = value.map(JSON.string) ?? .null }
    init(_ value: Int) { self = .number(Double(value)) }
}
