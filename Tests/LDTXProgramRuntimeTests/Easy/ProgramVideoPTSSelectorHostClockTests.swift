// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
//
// SPDX-License-Identifier: Apache-2.0

import Testing

@testable import LDTXProgramRuntime

@Suite
struct ProgramVideoPTSSelectorHostClockEasyTests {
  @Test func noConfiguredMasterUsesTheHostClock() {
    var selector = ProgramVideoPTSSelector()

    guard
      case .advanced(let presentationTime) = selector.select(
        masterCameraID: nil,
        masterPresentationTime: nil
      )
    else {
      Issue.record("An unconfigured master must advance using the host clock")
      return
    }

    #expect(presentationTime.isNumeric)
  }
}
