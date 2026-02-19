import Foundation

/// JSON-RPC 2.0 protocol structures for MCP
/// MCP (Model Context Protocol) uses JSON-RPC 2.0 over stdio

// MARK: - JSON-RPC Request

struct JSONRPCRequest: Codable {
    let jsonrpc: String
    let method: String
    let params: RequestParams?
    let id: RequestID?

    enum RequestID: Codable {
        case string(String)
        case int(Int)

        init(from decoder: Decoder) throws {
            let container = try decoder.singleValueContainer()
            if let intValue = try? container.decode(Int.self) {
                self = .int(intValue)
            } else if let stringValue = try? container.decode(String.self) {
                self = .string(stringValue)
            } else {
                throw DecodingError.typeMismatch(
                    RequestID.self,
                    DecodingError.Context(
                        codingPath: decoder.codingPath,
                        debugDescription: "Expected String or Int"
                    )
                )
            }
        }

        func encode(to encoder: Encoder) throws {
            var container = encoder.singleValueContainer()
            switch self {
            case .string(let value):
                try container.encode(value)
            case .int(let value):
                try container.encode(value)
            }
        }
    }

    struct RequestParams: Codable {
        let name: String?
        let arguments: [String: AnyCodable]?
    }
}

// MARK: - JSON-RPC Response

struct JSONRPCResponse: Codable {
    let jsonrpc: String
    let result: ResponseResult?
    let error: ResponseError?
    let id: JSONRPCRequest.RequestID?

    init(result: ResponseResult, id: JSONRPCRequest.RequestID?) {
        self.jsonrpc = "2.0"
        self.result = result
        self.error = nil
        self.id = id
    }

    init(error: ResponseError, id: JSONRPCRequest.RequestID?) {
        self.jsonrpc = "2.0"
        self.result = nil
        self.error = error
        self.id = id
    }
}

struct ResponseResult: Codable {
    let content: [ContentItem]

    struct ContentItem: Codable {
        let type: String
        let text: String
    }
}

struct ResponseError: Codable {
    let code: Int
    let message: String
    let data: AnyCodable?
}

// MARK: - Helper for dynamic JSON values

struct AnyCodable: Codable {
    let value: Any

    init(_ value: Any) {
        self.value = value
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()

        if let intValue = try? container.decode(Int.self) {
            value = intValue
        } else if let doubleValue = try? container.decode(Double.self) {
            value = doubleValue
        } else if let boolValue = try? container.decode(Bool.self) {
            value = boolValue
        } else if let stringValue = try? container.decode(String.self) {
            value = stringValue
        } else if let arrayValue = try? container.decode([AnyCodable].self) {
            value = arrayValue.map { $0.value }
        } else if let dictValue = try? container.decode([String: AnyCodable].self) {
            value = dictValue.mapValues { $0.value }
        } else {
            value = NSNull()
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()

        switch value {
        case let intValue as Int:
            try container.encode(intValue)
        case let doubleValue as Double:
            try container.encode(doubleValue)
        case let boolValue as Bool:
            try container.encode(boolValue)
        case let stringValue as String:
            try container.encode(stringValue)
        case let arrayValue as [Any]:
            try container.encode(arrayValue.map { AnyCodable($0) })
        case let dictValue as [String: Any]:
            try container.encode(dictValue.mapValues { AnyCodable($0) })
        case is NSNull:
            try container.encodeNil()
        default:
            try container.encodeNil()
        }
    }
}

// MARK: - Tool Parameters

/// Common parameters for tool calls
struct ToolArguments {
    let raw: [String: AnyCodable]

    init(_ dict: [String: AnyCodable]) {
        self.raw = dict
    }

    func getString(_ key: String) -> String? {
        guard let value = raw[key]?.value else { return nil }
        return value as? String
    }

    func getInt(_ key: String) -> Int? {
        guard let value = raw[key]?.value else { return nil }
        if let intValue = value as? Int {
            return intValue
        }
        if let doubleValue = value as? Double {
            return Int(doubleValue)
        }
        return nil
    }

    func getBool(_ key: String) -> Bool? {
        guard let value = raw[key]?.value else { return nil }
        return value as? Bool
    }
}
