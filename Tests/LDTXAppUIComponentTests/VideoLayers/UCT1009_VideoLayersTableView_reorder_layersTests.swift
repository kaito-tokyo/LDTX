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
    @Test func standardMovesSupportBothDirectionsAndMultipleRows() throws {
      let fixture = VideoLayersTestFixture()
      let editor = fixture.editor
      editor.move(fromOffsets: IndexSet(integer: 2), toOffset: 0)
      #expect(editor.layerIDs == [3, 1, 2])
      editor.move(fromOffsets: IndexSet(integer: 0), toOffset: 3)
      #expect(editor.layerIDs == [1, 2, 3])
      editor.move(fromOffsets: IndexSet([0, 1]), toOffset: 3)
      #expect(editor.layerIDs == [3, 1, 2])
      editor.move(fromOffsets: IndexSet(integer: 99), toOffset: 0)
      editor.move(fromOffsets: IndexSet(integer: 0), toOffset: 99)
      #expect(editor.layerIDs == [3, 1, 2])
      fixture.state.workspaceDefinition.programs = []
      editor.move(fromOffsets: IndexSet(integer: 0), toOffset: 3)
      #expect(
        fixture.state.workspacePreferences.landscapeProgramPreferences[100]?.videoLayerInternalIds
          == [3, 1, 2])
    }

    @Test func reorderingRetainsDraftsAndCannotChangeMembership() throws {
      let fixture = VideoLayersTestFixture()
      let row = try #require(fixture.editor.rows[1])
      row.edit("-", at: 0)
      fixture.state.isOutputActive = true
      fixture.editor.move(fromOffsets: IndexSet(integer: 0), toOffset: 3)
      #expect(fixture.editor.layerIDs == [2, 3, 1])
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
