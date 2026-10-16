// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
// SPDX-License-Identifier: Apache-2.0

import AppKit
import LDTXProtos
@testable import LDTXWorkspaceAppletUI
import SwiftUI
import Testing

extension AppUIComponentTestSuite {
  @Suite("UCT-1009: SwiftUI layer reordering", .serialized) @MainActor
  struct UCT1009VideoLayersTableViewIntegrationTestSuite {
    @Test func acceptsSingleLocalMovesAndRejectsForeignOrStaleTokens() throws {
      let fixture = VideoLayersTestFixture()
      let editor = fixture.editor
      let other = VideoLayersTestFixture()
      #expect(!editor.move([other.editor.token(for: 1)], before: 2))
      #expect(!editor.move([editor.token(for: 1), editor.token(for: 2)], before: 3))
      #expect(!editor.move([editor.token(for: 999)], before: 2))
      #expect(!editor.move([editor.token(for: 1)], before: 999))
      #expect(editor.move([editor.token(for: 3)], before: 1))
      #expect(editor.layerIDs == [3, 1, 2])
      #expect(editor.move([editor.token(for: 3)], before: nil))
      #expect(editor.layerIDs == [1, 2, 3])
      let token = editor.token(for: 1)
      fixture.state.workspaceDefinition.programs = [.with { $0.internalID = 200 }]
      #expect(!editor.move([token], before: nil))
    }

    @Test func reorderingRetainsDraftsAndCannotChangeMembership() throws {
      let fixture = VideoLayersTestFixture()
      let row = try #require(fixture.editor.rows[1])
      row.edit("-", at: 0)
      fixture.state.isOutputActive = true
      #expect(fixture.editor.move([fixture.editor.token(for: 1)], before: nil))
      fixture.editor.synchronizeRows()
      #expect(fixture.editor.rows[1] === row)
      #expect(row.strings[0] == "-")
      #expect(throws: WorkspaceSelectionError.self) {
        try fixture.editor.commitLayerOrder([1, 2, 4], programID: 100)
      }
      for ids: [Int64] in [[4, 1, 2], [2, 1, 5], []] {
        fixture.update(ids: ids)
        #expect(fixture.editor.rows.keys.sorted() == ids.sorted())
        if ids.contains(1) { #expect(fixture.editor.rows[1] === row) }
      }
      fixture.update(ids: [1])
      #expect(fixture.editor.rows[1] !== row)
    }
  }
}
