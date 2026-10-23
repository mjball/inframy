import Foundation

/// A small Sendable JSON value. The TV's payloads are loosely typed (numbers arrive as strings in one message
/// and as numbers in another, and some fields are JSON documents encoded as strings), so we keep them as JSON
/// and read fields leniently.
public enum JSON: Sendable, Equatable {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case array([JSON])
    case object([String: JSON])

    public subscript(key: String) -> JSON? {
        if case .object(let dict) = self { return dict[key] }
        return nil
    }

    public var stringValue: String? {
        switch self {
        case .string(let s): return s
        case .number(let n): return n.rounded() == n ? String(Int(n)) : String(n)
        case .bool(let b): return b ? "true" : "false"
        default: return nil
        }
    }

    public var intValue: Int? {
        switch self {
        case .number(let n): return Int(exactly: n.rounded())
        case .string(let s): return Int(s)
        default: return nil
        }
    }

    public var arrayValue: [JSON]? {
        if case .array(let a) = self { return a }
        return nil
    }

    public var objectValue: [String: JSON]? {
        if case .object(let o) = self { return o }
        return nil
    }

    /// For fields the TV sends as a JSON document inside a string (e.g. `content_list`, `conn_info`).
    /// Returns the value itself if it is already structured.
    public var decodedIfString: JSON? {
        switch self {
        case .string(let s): return try? JSON.parse(s)
        case .null: return nil
        default: return self
        }
    }

    public static func parse(_ text: String) throws -> JSON {
        try parse(Data(text.utf8))
    }

    public static func parse(_ data: Data) throws -> JSON {
        let obj = try JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
        return JSON(any: obj)
    }

    init(any: Any) {
        switch any {
        case is NSNull: self = .null
        case let n as NSNumber:
            // NSNumber bridges both Bool and numbers; tell them apart by type id.
            if CFGetTypeID(n) == CFBooleanGetTypeID() { self = .bool(n.boolValue) } else { self = .number(n.doubleValue) }
        case let s as String: self = .string(s)
        case let a as [Any]: self = .array(a.map(JSON.init(any:)))
        case let d as [String: Any]: self = .object(d.mapValues(JSON.init(any:)))
        default: self = .null
        }
    }

    var anyValue: Any {
        switch self {
        case .null: return NSNull()
        case .bool(let b): return b
        case .number(let n): return n.rounded() == n && abs(n) < 1e15 ? Int(n) as Any : n
        case .string(let s): return s
        case .array(let a): return a.map(\.anyValue)
        case .object(let o): return o.mapValues(\.anyValue)
        }
    }

    /// Compact serialization with sorted keys (stable output for tests and logs).
    public func serialized() -> String {
        if case .string(let s) = self {  // fragments: JSONSerialization handles these with .fragmentsAllowed
            let data = (try? JSONSerialization.data(withJSONObject: s, options: [.fragmentsAllowed])) ?? Data()
            return String(decoding: data, as: UTF8.self)
        }
        let data = (try? JSONSerialization.data(withJSONObject: anyValue,
                                                 options: [.sortedKeys, .withoutEscapingSlashes, .fragmentsAllowed])) ?? Data()
        return String(decoding: data, as: UTF8.self)
    }
}

extension JSON: ExpressibleByStringLiteral, ExpressibleByIntegerLiteral, ExpressibleByBooleanLiteral,
                ExpressibleByDictionaryLiteral, ExpressibleByArrayLiteral {
    public init(stringLiteral value: String) { self = .string(value) }
    public init(integerLiteral value: Int) { self = .number(Double(value)) }
    public init(booleanLiteral value: Bool) { self = .bool(value) }
    public init(dictionaryLiteral elements: (String, JSON)...) {
        self = .object(Dictionary(elements, uniquingKeysWith: { _, last in last }))
    }
    public init(arrayLiteral elements: JSON...) { self = .array(elements) }
}
