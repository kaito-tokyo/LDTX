// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
// SPDX-License-Identifier: Apache-2.0

import LDTXWorkspaceApplet
import Testing

@Suite
struct RuntimeModeSystemTestSuite {
  @Test func applicationHostProvidesTheUnitTestingRuntimeMode() {
    #expect(LDTXRuntimeMode.isUnitTesting)
  }
}
