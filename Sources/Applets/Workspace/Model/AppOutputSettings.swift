// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
//
// SPDX-License-Identifier: Apache-2.0

import Foundation

public struct AppPreviewSettings: Codable, Equatable, Sendable {
  public var prefersColor: Bool

  public init(prefersColor: Bool = false) {
    self.prefersColor = prefersColor
  }
}
