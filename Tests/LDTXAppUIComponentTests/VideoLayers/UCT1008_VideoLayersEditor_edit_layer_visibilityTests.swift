// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
// SPDX-License-Identifier: Apache-2.0

import AppKit
@testable import LDTXWorkspaceAppletUI
import Testing

extension AppUIComponentTestSuite {
  @Suite("UCT-1008: edit-layer-visibility", .serialized)
  @MainActor
  struct UCT1008VideoLayersEditorIntegrationTestSuite {
    init() { _ = UIComponentTestEnvironment.documentController }
    @Test("UCT-1008.1: Hide callbacks restore state on failure")
    func hideCallbacksRestoreStateOnFailure() throws {
      let fixture = VideoLayersTestFixture()
      let table = fixture.makeTable()
      var saved: [(UInt64, Bool)] = []
      var failures = 0
      fixture.update(table, ids: [1], setHidden: { id, hidden in saved.append((id, hidden)) })
      let row = try #require(table.rows[1])
      row.state.onSetHidden(!row.state.isHidden)
      #expect(saved.count == 1)
      #expect(saved[0].0 == 1 && saved[0].1)
      fixture.update(
        table, ids: [1],
        setHidden: { _, _ in throw WorkspaceSelectionError(message: "Rejected") },
        onError: { _ in failures += 1 })
      row.state.onSetHidden(!row.state.isHidden)
      #expect(!row.state.isHidden)
      #expect(failures == 1)
      #expect(table.rows[1] === row)
    }

  }
}
