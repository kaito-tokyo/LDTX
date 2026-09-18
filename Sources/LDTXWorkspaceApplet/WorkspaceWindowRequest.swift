// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
//
// SPDX-License-Identifier: Apache-2.0

import Foundation

public struct WorkspaceWindowRequest: Codable, Hashable, Sendable {
  public enum Source: Codable, Hashable, Sendable {
    case new(UUID)
    case file(URL)
  }

  public let source: Source

  public init(source: Source) {
    self.source = source
  }

  public static func new() -> Self { Self(source: .new(UUID())) }
  public static func file(_ url: URL) -> Self { Self(source: .file(url.standardizedFileURL)) }
}
