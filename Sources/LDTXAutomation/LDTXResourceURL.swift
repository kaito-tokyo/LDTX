// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
//
// SPDX-License-Identifier: Apache-2.0

import Foundation

public enum LDTXResourceURL {
  public static func unsavedWorkspace(sequence: Int) -> URL {
    precondition(sequence > 0)
    return URL(string: "ldtx://workspace/unsaved/\(sequence)")!
  }

  public static func canonicalWorkspaceURL(_ url: URL) throws -> URL {
    switch url.scheme?.lowercased() {
    case "file":
      guard url.isFileURL else {
        throw LDTXResourceURLError.invalidWorkspaceURL(url.absoluteString)
      }
      return url.standardizedFileURL
    case "ldtx":
      guard
        url.scheme == "ldtx",
        url.host == "workspace",
        url.user == nil,
        url.password == nil,
        url.port == nil,
        url.query == nil,
        url.fragment == nil
      else {
        throw LDTXResourceURLError.invalidWorkspaceURL(url.absoluteString)
      }
      let components = url.path.split(separator: "/", omittingEmptySubsequences: true)
      guard components.count == 2,
        components[0] == "unsaved",
        let sequence = Int(components[1]),
        sequence > 0,
        String(sequence) == components[1],
        url.path == "/unsaved/\(sequence)"
      else {
        throw LDTXResourceURLError.invalidWorkspaceURL(url.absoluteString)
      }
      return unsavedWorkspace(sequence: sequence)
    default:
      throw LDTXResourceURLError.invalidWorkspaceURL(url.absoluteString)
    }
  }

  public static func canonicalWorkspaceURL(_ value: String) throws -> URL {
    guard let url = URL(string: value), url.scheme != nil else {
      throw LDTXResourceURLError.invalidWorkspaceURL(value)
    }
    return try canonicalWorkspaceURL(url)
  }
}

public enum LDTXResourceURLError: Error, Equatable, LocalizedError {
  case invalidWorkspaceURL(String)

  public var errorDescription: String? {
    switch self {
    case .invalidWorkspaceURL(let value):
      "Invalid LDTX Workspace URL: \(value)"
    }
  }
}

public struct LDTXAutomationWindow: Codable, Equatable, Sendable {
  public var url: String
  public var kind: String
  public var title: String
  public var documentURL: String?

  public init(url: String, kind: String, title: String, documentURL: String? = nil) {
    self.url = url
    self.kind = kind
    self.title = title
    self.documentURL = documentURL
  }
}

public struct LDTXAutomationWindowList: Codable, Equatable, Sendable {
  public var windows: [LDTXAutomationWindow]

  public init(windows: [LDTXAutomationWindow]) {
    self.windows = windows
  }
}

extension Encodable {
  public func ldtxJSONRPCValue() throws -> JSONValue {
    try JSONDecoder().decode(JSONValue.self, from: JSONEncoder().encode(self))
  }
}

extension Decodable {
  public static func ldtxDecode(jsonRPCValue: JSONValue) throws -> Self {
    try JSONDecoder().decode(Self.self, from: JSONEncoder().encode(jsonRPCValue))
  }
}
