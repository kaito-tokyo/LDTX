// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
//
// SPDX-License-Identifier: Apache-2.0

import Foundation
import LDTXWorkspaceAppletModel

enum OutputFolderOverrideSelection {
  static func applying(
    enabled: Bool,
    selectedURL: URL?,
    to destination: OutputDestination
  ) -> OutputDestination? {
    var result = destination
    if enabled {
      guard let selectedURL else { return nil }
      result.overridesOutputFolder = true
      result.outputFolderPath = selectedURL.standardizedFileURL.path
    } else {
      result.overridesOutputFolder = false
      result.outputFolderPath = nil
    }
    return result
  }
}
