// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
//
// SPDX-License-Identifier: Apache-2.0

import Foundation
import XCTest

enum LDTXTestConfiguration {
  static let heavyMediaTestsEnvironmentKey = "LDTX_RUN_HEAVY_MEDIA_TESTS"

  static var runsHeavyMediaTests: Bool {
    let value = ProcessInfo.processInfo.environment[heavyMediaTestsEnvironmentKey]?
      .trimmingCharacters(in: .whitespacesAndNewlines)
      .lowercased()
    return value == "1" || value == "true" || value == "yes"
  }

  static func skipUnlessHeavyMediaTestsEnabled(_ testDescription: String) throws {
    guard runsHeavyMediaTests else {
      throw XCTSkip(
        "Set \(heavyMediaTestsEnvironmentKey)=1 to run heavy media test: \(testDescription).")
    }
  }
}
