// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
//
// SPDX-License-Identifier: Apache-2.0

import Foundation
import LDTXDiagnostics
import LDTXRecording

struct LDTXMCPServer {
  func run() async throws {
    while let line = readLine(strippingNewline: true) {
      guard !line.isEmpty else { continue }
      let decoded: Any
      do {
        decoded = try JSONSerialization.jsonObject(with: Data(line.utf8))
      } catch {
        try self.error(id: nil, code: -32700, message: "Parse error.")
        continue
      }
      guard let request = decoded as? [String: Any] else {
        try error(id: nil, code: -32600, message: "Invalid request.")
        continue
      }
      try await handle(request)
    }
  }

  private func handle(_ request: [String: Any]) async throws {
    let id = request["id"]
    guard request["jsonrpc"] as? String == "2.0", let method = request["method"] as? String else {
      try error(id: id, code: -32600, message: "Invalid request.")
      return
    }
    guard id != nil else { return }
    switch method {
    case "initialize":
      try result(
        id: id,
        value: [
          "protocolVersion": "2025-11-25",
          "capabilities": ["tools": [:]],
          "serverInfo": ["name": "ldtx", "version": "0.1.0"],
        ])
    case "ping": try result(id: id, value: [:])
    case "tools/list": try result(id: id, value: ["tools": Self.tools()])
    case "tools/call":
      guard let parameters = request["params"] as? [String: Any],
        let name = parameters["name"] as? String
      else {
        try error(id: id, code: -32602, message: "Invalid tool parameters.")
        return
      }
      try await call(
        name: name, arguments: parameters["arguments"] as? [String: Any] ?? [:], id: id)
    default: try error(id: id, code: -32601, message: "Method not found: \(method)")
    }
  }

  private func call(name: String, arguments: [String: Any], id: Any?) async throws {
    do {
      switch name {
      case "record_inspect":
        let path = try requiredPath(arguments)
        let package = try RecordingPackage(
          contentsOf: URL(fileURLWithPath: path).standardizedFileURL)
        try toolResult(
          id: id, structured: try dictionary(RecordingInspectionValue(package: package)))
      case "record_verify":
        let path = try requiredPath(arguments)
        let strict = arguments["strict"] as? Bool ?? false
        let package = try RecordingPackage(
          contentsOf: URL(fileURLWithPath: path).standardizedFileURL)
        if strict { try package.requireFinalized() }
        let warnings = try await RecordingPackageVerifier().verify(package, strict: strict)
        var value = try dictionary(RecordingInspectionValue(package: package))
        if !warnings.isEmpty { value["warnings"] = warnings }
        try toolResult(id: id, structured: value)
      case "record_remux":
        let path = try requiredPath(arguments)
        let strict = arguments["strict"] as? Bool ?? false
        let replace = arguments["replace"] as? Bool ?? false
        let packageURL = URL(fileURLWithPath: path).standardizedFileURL
        let package = try RecordingPackage(contentsOf: packageURL)
        if strict { try package.requireFinalized() }
        let warnings = try await RecordingPackageVerifier().verify(package, strict: strict)
        let output =
          (arguments["output"] as? String).map { URL(fileURLWithPath: $0).standardizedFileURL }
          ?? RecordingPackage.defaultRemuxOutputURL(for: packageURL)
        try await RecordingRemuxer().remux(package: package, to: output, replaceExisting: replace)
        var value: [String: Any] = ["output": output.path]
        if !warnings.isEmpty { value["warnings"] = warnings }
        try toolResult(id: id, structured: value)
      case "diagnostics_query_samples":
        guard let start = arguments["start"] as? String, let end = arguments["end"] as? String
        else {
          try error(id: id, code: -32602, message: "start and end are required.")
          return
        }
        let product: DiagnosticsProduct?
        if let rawProduct = arguments["product"] as? String {
          guard let parsed = DiagnosticsProduct(rawValue: rawProduct) else {
            try error(id: id, code: -32602, message: "product must be ldtx or tiny.")
            return
          }
          product = parsed
        } else {
          product = nil
        }
        let limit = arguments["limit"] as? Int ?? 500
        guard (1...1_000).contains(limit) else {
          throw LDTXMCPParameterError.invalidLimit
        }
        let cursor: DiagnosticsSampleCursor?
        if let encodedCursor = arguments["cursor"] as? String {
          guard let data = Data(base64Encoded: encodedCursor),
            let decoded = try? JSONDecoder().decode(DiagnosticsSampleCursor.self, from: data)
          else {
            throw LDTXMCPParameterError.invalidCursor
          }
          cursor = decoded
        } else {
          cursor = nil
        }
        let page = try LDTXHelper.queryDiagnosticsSamplePage(
          start: start,
          end: end,
          product: product,
          applicationVersion: arguments["appVersion"] as? String,
          bundleIdentifier: arguments["bundleId"] as? String,
          cursor: cursor,
          limit: limit
        )
        var structured: [String: Any] = ["samples": try array(page.samples)]
        if let nextCursor = page.nextCursor {
          structured["nextCursor"] = try JSONEncoder().encode(nextCursor).base64EncodedString()
        }
        try toolResult(id: id, structured: structured)
      default: try error(id: id, code: -32602, message: "Unknown tool: \(name)")
      }
    } catch let diagnosticsError as DiagnosticsDatabaseError {
      try toolResult(
        id: id,
        structured: [
          "error": [
            "kind": diagnosticsErrorKind(diagnosticsError),
            "message": diagnosticsError.localizedDescription,
          ]
        ],
        text: diagnosticsError.localizedDescription,
        isError: true
      )
    } catch {
      try toolResult(id: id, text: error.localizedDescription, isError: true)
    }
  }

  private func toolResult(
    id: Any?, structured: [String: Any] = [:], text: String? = nil, isError: Bool = false
  ) throws {
    let body: String
    if let text {
      body = text
    } else {
      body = String(
        decoding: try JSONSerialization.data(
          withJSONObject: structured, options: [.prettyPrinted, .sortedKeys]),
        as: UTF8.self
      )
    }
    var value: [String: Any] = [
      "content": [["type": "text", "text": body]], "structuredContent": structured,
    ]
    if isError { value["isError"] = true }
    try result(id: id, value: value)
  }

  private func dictionary(_ value: some Encodable) throws -> [String: Any] {
    try JSONSerialization.jsonObject(with: JSONEncoder().encode(value)) as? [String: Any] ?? [:]
  }

  private func array(_ value: some Encodable) throws -> [Any] {
    try JSONSerialization.jsonObject(with: JSONEncoder().encode(value)) as? [Any] ?? []
  }

  private func requiredPath(_ arguments: [String: Any]) throws -> String {
    guard let path = arguments["path"] as? String, !path.isEmpty else {
      throw LDTXMCPParameterError.pathRequired
    }
    return path
  }

  private func diagnosticsErrorKind(_ error: DiagnosticsDatabaseError) -> String {
    switch error {
    case .invalidApplicationVersion: "invalid_application_version"
    case .invalidBundleIdentifier: "invalid_bundle_identifier"
    case .databaseNotFound: "database_not_found"
    case .databaseInUse: "database_in_use"
    case .schemaMismatch: "schema_mismatch"
    case .sqlite: "database_error"
    case .invalidTimeRange: "invalid_time_range"
    }
  }

  private func result(id: Any?, value: [String: Any]) throws {
    try write(["jsonrpc": "2.0", "id": id ?? NSNull(), "result": value])
  }
  private func error(id: Any?, code: Int, message: String) throws {
    try write([
      "jsonrpc": "2.0", "id": id ?? NSNull(), "error": ["code": code, "message": message],
    ])
  }
  private func write(_ value: [String: Any]) throws {
    var data = try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys])
    data.append(0x0A)
    try FileHandle.standardOutput.write(contentsOf: data)
  }

  static func tools(
    requiresExplicitDiagnosticsSelectors: Bool = LDTXHelper.diagnosticsHostApplicationBundle()
      == nil
  ) -> [[String: Any]] {
    let pathSchema: [String: Any] = [
      "type": "object", "properties": ["path": ["type": "string"]], "required": ["path"],
      "additionalProperties": false,
    ]
    let verifySchema: [String: Any] = [
      "type": "object",
      "properties": [
        "path": ["type": "string"],
        "strict": ["type": "boolean"],
      ],
      "required": ["path"],
      "additionalProperties": false,
    ]
    let remuxSchema: [String: Any] = [
      "type": "object",
      "properties": [
        "path": ["type": "string"],
        "output": ["type": "string"],
        "replace": ["type": "boolean"],
        "strict": ["type": "boolean"],
      ],
      "required": ["path"],
      "additionalProperties": false,
    ]
    let requiredDiagnosticsProperties =
      requiresExplicitDiagnosticsSelectors
      ? ["start", "end", "appVersion", "bundleId"] : ["start", "end"]
    let diagnosticsSchema: [String: Any] = [
      "type": "object",
      "properties": [
        "start": ["type": "string", "description": "Inclusive RFC 3339 UTC timestamp."],
        "end": ["type": "string", "description": "Exclusive RFC 3339 UTC timestamp."],
        "product": ["type": "string", "enum": ["ldtx", "tiny"]],
        "appVersion": ["type": "string"],
        "bundleId": ["type": "string"],
        "cursor": ["type": "string", "description": "Opaque cursor returned by the prior page."],
        "limit": ["type": "integer", "minimum": 1, "maximum": 1_000, "default": 500],
      ],
      "required": requiredDiagnosticsProperties,
      "additionalProperties": false,
    ]
    return [
      [
        "name": "record_inspect", "description": "Read an LDTX recording package.",
        "inputSchema": pathSchema,
      ],
      [
        "name": "record_verify", "description": "Verify an LDTX recording package.",
        "inputSchema": verifySchema,
      ],
      [
        "name": "record_remux", "description": "Remux an LDTX recording package.",
        "inputSchema": remuxSchema,
      ],
      [
        "name": "diagnostics_query_samples",
        "description": "Read process load sample rows in a UTC half-open time range.",
        "inputSchema": diagnosticsSchema,
      ],
    ]
  }
}

private enum LDTXMCPParameterError: LocalizedError {
  case pathRequired
  case invalidCursor
  case invalidLimit

  var errorDescription: String? {
    switch self {
    case .pathRequired: "path is required."
    case .invalidCursor: "cursor is invalid."
    case .invalidLimit: "limit must be between 1 and 1000."
    }
  }
}
