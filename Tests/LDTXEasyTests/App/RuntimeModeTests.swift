// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
// SPDX-License-Identifier: Apache-2.0

import LDTXWorkspaceAppletUI
import Testing

@Suite
struct RuntimeModeUnitTestSuite {
  @Test func applicationHostProvidesTheUnitTestingRuntimeMode() {
    #expect(LDTXRuntimeMode.isUnitTesting)
  }
}
