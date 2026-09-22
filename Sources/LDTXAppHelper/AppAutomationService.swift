// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
//
// SPDX-License-Identifier: Apache-2.0

import Foundation

/// The shared boundary for operations that control the LDTX application.
///
/// Concrete operations are intentionally not defined yet. The CLI and MCP
/// surfaces use this boundary so that future App Automation work is not
/// implemented twice.
public protocol AppAutomationService: Sendable {
  func availableOperations() -> [String]
  func execute(operation: String) throws
}

public enum AppAutomationError: Error, LocalizedError, Sendable {
  case operationUnavailable(String)

  public var errorDescription: String? {
    switch self {
    case .operationUnavailable:
      return "No App Automation operations are available yet."
    }
  }
}

public struct EmptyAppAutomationService: AppAutomationService, Sendable {
  public init() {}

  public func availableOperations() -> [String] { [] }

  public func execute(operation: String) throws {
    throw AppAutomationError.operationUnavailable(operation)
  }
}
