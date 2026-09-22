// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
//
// SPDX-License-Identifier: Apache-2.0

import Foundation

public struct AppAutomationMCPServer: Sendable {
  private let service: any AppAutomationService

  public init(service: any AppAutomationService = EmptyAppAutomationService()) {
    self.service = service
  }

  public func run() async throws {
    while let line = readLine(strippingNewline: true) {
      guard !line.isEmpty else { continue }
      let request: [String: Any]
      do {
        guard let value = try JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any]
        else {
          try writeError(id: nil, code: -32600, message: "Invalid request.")
          continue
        }
        request = value
      } catch {
        try writeError(id: nil, code: -32700, message: "Parse error.")
        continue
      }
      try await handle(request)
    }
  }

  private func handle(_ request: [String: Any]) async throws {
    let id = request["id"]
    guard request["jsonrpc"] as? String == "2.0",
      let method = request["method"] as? String
    else {
      try writeError(id: id, code: -32600, message: "Invalid request.")
      return
    }
    guard id != nil else { return }

    switch method {
    case "initialize":
      try writeResult(
        id: id,
        value: [
          "protocolVersion": "2025-11-25",
          "capabilities": ["tools": [:]],
          "serverInfo": ["name": "ldtx-app", "version": "0.1.0"],
        ])
    case "ping":
      try writeResult(id: id, value: [:])
    case "tools/list":
      try writeResult(
        id: id,
        value: ["tools": service.availableOperations().map { ["name": $0] }])
    case "tools/call":
      do {
        let params = request["params"] as? [String: Any] ?? [:]
        let name = params["name"] as? String ?? ""
        try service.execute(operation: name)
        try writeResult(id: id, value: [:])
      } catch {
        try writeError(id: id, code: -32602, message: error.localizedDescription)
      }
    default:
      try writeError(id: id, code: -32601, message: "Method not found: \(method)")
    }
  }

  private func writeResult(id: Any?, value: [String: Any]) throws {
    try write(["jsonrpc": "2.0", "id": id ?? NSNull(), "result": value])
  }

  private func writeError(id: Any?, code: Int, message: String) throws {
    try write([
      "jsonrpc": "2.0",
      "id": id ?? NSNull(),
      "error": ["code": code, "message": message],
    ])
  }

  private func write(_ value: [String: Any]) throws {
    var data = try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys])
    data.append(0x0A)
    try FileHandle.standardOutput.write(contentsOf: data)
  }
}
