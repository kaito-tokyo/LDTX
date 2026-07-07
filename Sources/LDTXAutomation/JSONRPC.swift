// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
//
// SPDX-License-Identifier: Apache-2.0

import Foundation

public enum JSONRPCID: Codable, Equatable, Hashable, Sendable {
    case string(String)
    case number(Int)

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let value = try? container.decode(Int.self) {
            self = .number(value)
        } else {
            self = .string(try container.decode(String.self))
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case let .string(value):
            try container.encode(value)
        case let .number(value):
            try container.encode(value)
        }
    }
}

public struct JSONRPCRequest: Codable, Equatable, Sendable {
    public var jsonrpc: String
    public var id: JSONRPCID?
    public var method: String
    public var params: JSONValue?

    public init(id: JSONRPCID? = nil, method: String, params: JSONValue? = nil) {
        jsonrpc = "2.0"
        self.id = id
        self.method = method
        self.params = params
    }

    public var isValid: Bool {
        jsonrpc == "2.0" && !method.isEmpty
    }
}

public struct JSONRPCResponse: Codable, Equatable, Sendable {
    public var jsonrpc: String
    public var id: JSONRPCID?
    public var result: JSONValue?
    public var error: JSONRPCError?

    public init(id: JSONRPCID?, result: JSONValue) {
        jsonrpc = "2.0"
        self.id = id
        self.result = result
        error = nil
    }

    public init(id: JSONRPCID?, error: JSONRPCError) {
        jsonrpc = "2.0"
        self.id = id
        result = nil
        self.error = error
    }
}

public struct JSONRPCError: Codable, Error, Equatable, Sendable {
    public var code: Int
    public var message: String
    public var data: JSONValue?

    public init(code: Int, message: String, data: JSONValue? = nil) {
        self.code = code
        self.message = message
        self.data = data
    }

    public static func methodNotFound(_ method: String) -> JSONRPCError {
        JSONRPCError(code: -32601, message: "Method not found: \(method)")
    }

    public static func invalidRequest(_ message: String = "Invalid request.") -> JSONRPCError {
        JSONRPCError(code: -32600, message: message)
    }

    public static func invalidParams(_ message: String) -> JSONRPCError {
        JSONRPCError(code: -32602, message: message)
    }

    public static func internalError(_ message: String) -> JSONRPCError {
        JSONRPCError(code: -32603, message: message)
    }
}

public enum JSONRPCCoding {
    public static let encoder = JSONEncoder()
    public static let decoder = JSONDecoder()

    public static func encode<T: Encodable>(_ value: T) throws -> Data {
        try encoder.encode(value)
    }

    public static func encodeLine<T: Encodable>(_ value: T) throws -> Data {
        try encode(value)
    }

    public static func decodeRequest(_ data: Data) throws -> JSONRPCRequest {
        do {
            let request = try decoder.decode(JSONRPCRequest.self, from: data)
            guard request.isValid else {
                throw JSONRPCError.invalidRequest()
            }
            return request
        } catch let error as JSONRPCError {
            throw error
        } catch {
            throw JSONRPCError.invalidRequest()
        }
    }

    public static func decodeResponse(_ data: Data) throws -> JSONRPCResponse {
        try decoder.decode(JSONRPCResponse.self, from: data)
    }
}
