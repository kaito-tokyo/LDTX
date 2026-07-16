// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
//
// SPDX-License-Identifier: Apache-2.0

import Foundation
import LDTXRecording

struct LDTXMCPServer {
  static let protocolVersion = "2025-11-25"

  func run() async throws {
    while let line = readLine(strippingNewline: true) {
      guard !line.isEmpty else { continue }
      do {
        guard
          let request = try JSONSerialization.jsonObject(with: Data(line.utf8))
            as? [String: Any]
        else {
          try writeError(id: nil, code: -32600, message: "Invalid request.")
          continue
        }
        try await handle(request)
      } catch {
        try writeError(id: nil, code: -32700, message: "Parse error.")
      }
    }
  }

  private func handle(_ request: [String: Any]) async throws {
    guard request["jsonrpc"] as? String == "2.0",
      let method = request["method"] as? String
    else {
      try writeError(id: request["id"], code: -32600, message: "Invalid request.")
      return
    }
    let id = request["id"]
    guard id != nil else { return }

    switch method {
    case "initialize":
      try writeResult(
        id: id,
        result: [
          "protocolVersion": Self.protocolVersion,
          "capabilities": ["tools": [:]],
          "serverInfo": [
            "name": "ldtx",
            "version": "0.1.0",
            "description": "Inspect and remux LDTX recording packages.",
          ],
        ])
    case "ping":
      try writeResult(id: id, result: [:])
    case "tools/list":
      try writeResult(id: id, result: ["tools": Self.tools])
    case "tools/call":
      guard let params = request["params"] as? [String: Any],
        let name = params["name"] as? String
      else {
        try writeError(id: id, code: -32602, message: "Invalid tool parameters.")
        return
      }
      let arguments = params["arguments"] as? [String: Any] ?? [:]
      try await callTool(name: name, arguments: arguments, id: id)
    default:
      try writeError(id: id, code: -32601, message: "Method not found: \(method)")
    }
  }

  private func callTool(name: String, arguments: [String: Any], id: Any?) async throws {
    do {
      guard let path = arguments["path"] as? String, !path.isEmpty else {
        try writeError(id: id, code: -32602, message: "path is required.")
        return
      }
      let packageURL = URL(fileURLWithPath: path).standardizedFileURL
      let package = try RecordingPackage(contentsOf: packageURL)
      switch name {
      case "record_inspect":
        let summary = summary(for: package)
        try writeToolResult(id: id, text: jsonString(summary), structuredContent: summary)
      case "record_verify":
        let strict = arguments["strict"] as? Bool ?? false
        try checkFinalization(of: package, strict: strict)
        var warnings = try await RecordingPackageVerifier().verify(package, strict: strict)
        if let warning = recoveryWarning(for: package) { warnings.insert(warning, at: 0) }
        var summary = summary(for: package)
        if !warnings.isEmpty { summary["warnings"] = warnings }
        try writeToolResult(
          id: id,
          text: warnings.map { "Warning: \($0)" }.joined(separator: "\n")
            + (warnings.isEmpty ? "" : "\n")
            + "OK: \(package.identifier) (\(package.audioTracks.count) audio tracks)",
          structuredContent: summary
        )
      case "record_remux":
        let strict = arguments["strict"] as? Bool ?? false
        try checkFinalization(of: package, strict: strict)
        var warnings = try await RecordingPackageVerifier().verify(package, strict: strict)
        if let warning = recoveryWarning(for: package) { warnings.insert(warning, at: 0) }
        let outputURL =
          (arguments["output"] as? String).map {
            URL(fileURLWithPath: $0).standardizedFileURL
          } ?? RecordingPackage.defaultRemuxOutputURL(for: packageURL)
        try await RecordingRemuxer().remux(
          package: package,
          to: outputURL,
          replaceExisting: arguments["replace"] as? Bool ?? false
        )
        var result: [String: Any] = ["output": outputURL.path]
        if !warnings.isEmpty { result["warnings"] = warnings }
        try writeToolResult(
          id: id,
          text: warnings.map { "Warning: \($0)" }.joined(separator: "\n")
            + (warnings.isEmpty ? "" : "\n") + outputURL.path,
          structuredContent: result
        )
      default:
        try writeError(id: id, code: -32602, message: "Unknown tool: \(name)")
      }
    } catch {
      try writeToolResult(id: id, text: error.localizedDescription, isError: true)
    }
  }

  private func checkFinalization(of package: RecordingPackage, strict: Bool) throws {
    if strict {
      try package.requireFinalized()
    }
  }

  private func recoveryWarning(for package: RecordingPackage) -> String? {
    package.isFinalized
      ? nil : "Recording package is not finalized; attempting recovery."
  }

  private func summary(for package: RecordingPackage) -> [String: Any] {
    var summary: [String: Any] = [
      "formatVersion": package.formatVersion,
      "identifier": package.identifier,
      "finalized": package.isFinalized,
      "mainMediaFile": package.mainMediaPath,
      "audioTracks": package.audioTracks.map { track in
        [
          "identifier": track.identifier,
          "name": track.name,
          "mediaFile": track.mediaPath,
        ]
      },
    ]
    summary["manifestFile"] = package.manifestPath
    return summary
  }

  private func writeToolResult(
    id: Any?,
    text: String,
    structuredContent: [String: Any]? = nil,
    isError: Bool = false
  ) throws {
    var result: [String: Any] = [
      "content": [["type": "text", "text": text]]
    ]
    result["structuredContent"] = structuredContent
    if isError { result["isError"] = true }
    try writeResult(id: id, result: result)
  }

  private func writeResult(id: Any?, result: [String: Any]) throws {
    try write(["jsonrpc": "2.0", "id": id ?? NSNull(), "result": result])
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

  private func jsonString(_ value: [String: Any]) throws -> String {
    String(
      decoding: try JSONSerialization.data(
        withJSONObject: value, options: [.prettyPrinted, .sortedKeys]),
      as: UTF8.self
    )
  }

  private static var pathSchema: [String: Any] {
    [
      "type": "object",
      "properties": [
        "path": ["type": "string", "description": "Path to an .ldtxrecord package."]
      ],
      "required": ["path"],
      "additionalProperties": false,
    ]
  }

  private static var verificationSchema: [String: Any] {
    [
      "type": "object",
      "properties": [
        "path": ["type": "string", "description": "Path to an .ldtxrecord package."],
        "strict": [
          "type": "boolean",
          "default": false,
          "description": "Reject an unfinalized package instead of attempting recovery.",
        ],
      ],
      "required": ["path"],
      "additionalProperties": false,
    ]
  }

  private static var tools: [[String: Any]] {
    [
      [
        "name": "record_inspect",
        "description": "Read the format and track information from an LDTX recording package.",
        "inputSchema": pathSchema,
      ],
      [
        "name": "record_verify",
        "description": "Verify the structure and referenced files of an LDTX recording package.",
        "inputSchema": verificationSchema,
      ],
      [
        "name": "record_remux",
        "description": "Remux an LDTX recording package and all audio tracks to MP4.",
        "inputSchema": [
          "type": "object",
          "properties": [
            "path": ["type": "string", "description": "Path to an .ldtxrecord package."],
            "output": ["type": "string", "description": "Optional output MP4 path."],
            "replace": ["type": "boolean", "default": false],
            "strict": [
              "type": "boolean",
              "default": false,
              "description": "Reject an unfinalized package instead of attempting recovery.",
            ],
          ],
          "required": ["path"],
          "additionalProperties": false,
        ],
      ],
    ]
  }
}
