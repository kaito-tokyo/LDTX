// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
// SPDX-License-Identifier: Apache-2.0

import AppKit
import LDTXProtos
@testable import LDTXWorkspaceAppletUI
import SwiftUI
import Testing

extension AppUIComponentTestSuite {
  @Suite("UCT-1007: SwiftUI selected Program", .serialized) @MainActor
  struct UCT1007VideoLayersEditorIntegrationTestSuite {
    init() { _ = UIComponentTestEnvironment.documentController }

    @Test func namesVisibilityAndDraftsFollowCurrentDefinitions() throws {
      let fixture = VideoLayersTestFixture()
      let row = try #require(fixture.editor.rows[1])
      row.edit("-", at: 0)
      fixture.state.workspaceDefinition.videoComponents[0].vfxSource.displayName = "Renamed"
      fixture.state.workspacePreferences.landscapeProgramPreferences[100, default: .init()]
        .videoLayerHidden[1] = true
      fixture.editor.synchronizeRows()
      #expect(row.name == "Renamed")
      #expect(row.isHidden)
      #expect(row.strings[0] == "-")
      fixture.state.workspaceDefinition.videoComponents.removeAll()
      fixture.editor.synchronizeRows()
      #expect(row.name == "Missing Video Layer")
      #expect(!row.supportsPlacement)
    }

    @Test func programChangeDiscardsDraftAndInvalidatesOldCallbacks() throws {
      let fixture = VideoLayersTestFixture()
      let old = try #require(fixture.editor.rows[1])
      old.edit("-", at: 0)
      fixture.state.workspaceDefinition.programs = [.with { $0.internalID = 200 }]
      fixture.state.workspacePreferences.landscapeProgramPreferences[200] =
        fixture.state.workspacePreferences.landscapeProgramPreferences[100]
      fixture.editor.synchronizeRows()
      #expect(fixture.editor.rows[1] !== old)
      #expect(fixture.editor.rows[1]?.hasLocalTextChanges == false)
      let before = fixture.state.workspacePreferences
      old.edit("960", at: 0)
      old.onSetHidden(true)
      #expect(fixture.state.workspacePreferences == before)
    }

    @Test func canvasEditorsRemainIndependent() throws {
      let fixture = VideoLayersTestFixture()
      let portrait = VideoLayersEditorState(
        stateService: fixture.state, appletData: fixture.data, target: .portrait)
      #expect(portrait.layerIDs.isEmpty)
      fixture.state.workspacePreferences.portraitProgramPreferences[100, default: .init()]
        .videoLayerInternalIds = [2]
      portrait.synchronizeRows()
      #expect(portrait.rows.keys.sorted() == [2])
      #expect(fixture.editor.rows.keys.sorted() == [1, 2, 3])
    }

    @Test func onlyPositionableComponentsExposePlacement() throws {
      let fixture = VideoLayersTestFixture(ids: [1, 2, 3])
      fixture.state.workspaceDefinition.videoComponents = [
        .with { $0.vfxSource.internalID = 1 },
        .with { $0.clock.internalID = 2 },
        WorkspaceResourceFactory.makeSolidColor(id: 3, name: "Fill"),
      ]
      fixture.editor.synchronizeRows()
      #expect(fixture.editor.rows[1]?.supportsPlacement == true)
      #expect(fixture.editor.rows[2]?.supportsPlacement == true)
      #expect(fixture.editor.rows[3]?.supportsPlacement == false)
    }
  }
}
