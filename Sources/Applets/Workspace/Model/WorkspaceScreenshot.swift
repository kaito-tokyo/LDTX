// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
// SPDX-License-Identifier: Apache-2.0

import Foundation

public struct WorkspaceScreenshot: Sendable {
  public enum ProgramCanvas: String, Sendable {
    case landscape = "Landscape"
    case portrait = "Portrait"
  }

  public let url: URL
  public let programCanvas: ProgramCanvas?

  public init(url: URL, programCanvas: ProgramCanvas? = nil) {
    self.url = url
    self.programCanvas = programCanvas
  }
}
