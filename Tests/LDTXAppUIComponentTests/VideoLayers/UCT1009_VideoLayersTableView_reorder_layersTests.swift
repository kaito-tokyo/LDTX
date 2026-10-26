// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
// SPDX-License-Identifier: Apache-2.0

import AppKit
import LDTXCorelibs
@testable import LDTXWorkspaceAppletUI
import SwiftUI
import Testing

extension AppUIComponentTestSuite {
  @Suite("UCT-1009: SwiftUI layer reordering", .serialized) @MainActor
  struct UCT1009VideoLayersTableViewIntegrationTestSuite {
    struct LayerMove: Sendable, Codable {
      let source: [Int]
      let destination: Int
      let programPresent: Bool
      let expected: [Int64]
    }

    @Test(
      "LUB-1048: Layer move changes only valid ordering",
      arguments: [
        LayerMove(source: [2], destination: 0, programPresent: true, expected: [3, 1, 2]),
        LayerMove(source: [0], destination: 3, programPresent: true, expected: [2, 3, 1]),
        LayerMove(source: [0, 1], destination: 3, programPresent: true, expected: [3, 1, 2]),
        LayerMove(source: [99], destination: 0, programPresent: true, expected: [1, 2, 3]),
        LayerMove(source: [0], destination: 99, programPresent: true, expected: [1, 2, 3]),
        LayerMove(source: [0], destination: 3, programPresent: false, expected: [1, 2, 3]),
      ])
    func layerMove(_ data: LayerMove) {
      let fixture = VideoLayersTestFixture()
      if !data.programPresent {
        fixture.state.editWorkspace(undoManager: nil) { $0.definition.programs = [] }
      }
      fixture.editor.move(fromOffsets: IndexSet(data.source), toOffset: data.destination)
      #expect(
        fixture.state.workspacePreferences.landscapeProgramPreferences[100]?.videoLayerInternalIds
          == data.expected)
    }

    @Test("LUB-1048: Reordering retains drafts and cannot change membership")
    func reorderingRetainsDraftsAndCannotChangeMembership() throws {
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
