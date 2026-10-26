// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
// SPDX-License-Identifier: Apache-2.0

import AppKit
import LDTXCorelibs
@testable import LDTXWorkspaceAppletUI
import SwiftUI
import Testing

extension AppUIComponentTestSuite {
  @Suite("UCT-1007: SwiftUI selected Program", .serialized) @MainActor
  struct UCT1007VideoLayersEditorIntegrationTestSuite {
    init() { _ = UIComponentTestEnvironment.documentController }

    @Test("LUB-1048: Names visibility and drafts follow current definitions")
    func namesVisibilityAndDraftsFollowCurrentDefinitions() throws {
      let fixture = VideoLayersTestFixture()
      let row = try #require(fixture.editor.rows[1])
      row.edit("-", at: 0)
      fixture.state.editWorkspace(undoManager: nil) { workspace in
        guard case .vfxSource(var source) = workspace.definition.videoComponents[0].videoComponent
        else {
          Issue.record("Missing source")
          return
        }
        source.displayName = "Renamed"
        workspace.definition.videoComponents[0].videoComponent = .vfxSource(source)
      }
      fixture.state.editWorkspace(undoManager: nil) { workspace in
        workspace.preferences.landscapeProgramPreferences[100, default: .init()]
          .videoLayerHidden[1] = true
      }
      fixture.editor.synchronizeRows()
      #expect(row.name == "Renamed")
      #expect(row.isHidden)
      #expect(row.strings[0] == "-")
      fixture.state.editWorkspace(undoManager: nil) { workspace in
        workspace.definition.videoComponents.removeAll()
      }
      fixture.editor.synchronizeRows()
      #expect(row.name == "Missing Video Layer")
      #expect(!row.supportsPlacement)
    }

    @Test("LUB-1048: Program change discards draft and invalidates old callbacks")
    func programChangeDiscardsDraftAndInvalidatesOldCallbacks() throws {
      let fixture = VideoLayersTestFixture()
      let old = try #require(fixture.editor.rows[1])
      old.edit("-", at: 0)
      fixture.state.editWorkspace(undoManager: nil) { workspace in
        workspace.definition.programs = [.with { $0.internalID = 200 }]
      }
      fixture.state.editWorkspace(undoManager: nil) { workspace in
        workspace.preferences.landscapeProgramPreferences[200] =
          fixture.state.workspacePreferences.landscapeProgramPreferences[100]
      }
      fixture.editor.synchronizeRows()
      #expect(fixture.editor.rows[1] !== old)
      #expect(fixture.editor.rows[1]?.hasLocalTextChanges == false)
      let before = fixture.state.workspacePreferences
      old.edit("960", at: 0)
      old.onSetHidden(true, nil)
      #expect(fixture.state.workspacePreferences == before)
    }

    @Test("LUB-1048: Canvas editors remain independent") func canvasEditorsRemainIndependent()
      throws
    {
      let fixture = VideoLayersTestFixture()
      let portrait = VideoLayersEditorState(
        stateService: fixture.state, appletData: fixture.data, target: .portrait)
      #expect(portrait.layerIDs.isEmpty)
      fixture.state.editWorkspace(undoManager: nil) { workspace in
        workspace.preferences.portraitProgramPreferences[100, default: .init()]
          .videoLayerInternalIds = [2]
      }
      portrait.synchronizeRows()
      #expect(portrait.rows.keys.sorted() == [2])
      #expect(fixture.editor.rows.keys.sorted() == [1, 2, 3])
    }

    @Test("LUB-1048: Only positionable components expose placement")
    func onlyPositionableComponentsExposePlacement() throws {
      let fixture = VideoLayersTestFixture(ids: [1, 2, 3, 4])
      try fixture.state.editWorkspace(undoManager: nil) { workspace in
        workspace.definition.videoComponents = [
          .with { $0.videoComponent = .vfxSource(.with { $0.internalID = 1 }) },
          .with { $0.videoComponent = .clock(.with { $0.internalID = 2 }) },
          WorkspaceResourceFactory.makeSolidColor(id: 3, name: "Fill"),
          try WorkspaceResourceFactory.makeDynamicText(id: 4, name: "Text"),
        ]
      }
      fixture.editor.synchronizeRows()
      #expect(fixture.editor.rows[1]?.supportsPlacement == true)
      #expect(fixture.editor.rows[2]?.supportsPlacement == true)
      #expect(fixture.editor.rows[3]?.supportsPlacement == false)
      #expect(fixture.editor.rows[4]?.supportsPlacement == true)
    }
  }
}
