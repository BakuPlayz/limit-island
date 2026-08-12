import Foundation

/// A decoded JSON value of unknown shape.
///
/// Hook payloads carry a `tool_input` whose keys differ per tool — `command` for
/// Bash, `file_path`/`old_string`/`new_string` for Edit, and whatever an MCP server
/// invented for its own. Modelling each one would mean the permission card breaks
/// the first time a tool it has never seen arrives, so the payload is kept as data
/// and read by key at the point of use.
enum JSONValue: Codable, Hashable, Sendable {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() { self = .null }
        else if let value = try? container.decode(Bool.self) { self = .bool(value) }
        else if let value = try? container.decode(Double.self) { self = .number(value) }
        else if let value = try? container.decode(String.self) { self = .string(value) }
        else if let value = try? container.decode([JSONValue].self) { self = .array(value) }
        else if let value = try? container.decode([String: JSONValue].self) { self = .object(value) }
        else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "unrepresentable JSON")
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .null: try container.encodeNil()
        case let .bool(value): try container.encode(value)
        case let .number(value): try container.encode(value)
        case let .string(value): try container.encode(value)
        case let .array(value): try container.encode(value)
        case let .object(value): try container.encode(value)
        }
    }

    // MARK: - Reading

    subscript(key: String) -> JSONValue? {
        guard case let .object(members) = self else { return nil }
        return members[key]
    }

    var stringValue: String? {
        switch self {
        case let .string(value): value
        // Identifiers arrive numeric often enough to be worth tolerating; a session
        // id that decodes as a double would otherwise silently read as absent.
        case let .number(value): value == value.rounded() ? String(Int(value)) : String(value)
        case let .bool(value): String(value)
        default: nil
        }
    }

    var objectValue: [String: JSONValue]? {
        guard case let .object(value) = self else { return nil }
        return value
    }

    var arrayValue: [JSONValue]? {
        guard case let .array(value) = self else { return nil }
        return value
    }

    /// Reads a key that a CLI may spell either way. Hook payloads are snake_case,
    /// but the tools' own inputs are not consistently either.
    func string(_ keys: String...) -> String? {
        for key in keys {
            if let value = self[key]?.stringValue, !value.isEmpty { return value }
        }
        return nil
    }
}
