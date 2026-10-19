// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
// SPDX-License-Identifier: Apache-2.0

@testable import LDTXWorkspaceAppletUI
import Testing

@Suite
@MainActor
struct WorkspaceResourceFactoryUnitTestSuite {
  @Test func generatedIDsArePositiveAndOdd() {
    for _ in 0..<100 {
      let id = WorkspaceResourceFactory.nextInternalID()
      #expect(id > 0)
      #expect(id & 1 == 1)
    }
  }

}
