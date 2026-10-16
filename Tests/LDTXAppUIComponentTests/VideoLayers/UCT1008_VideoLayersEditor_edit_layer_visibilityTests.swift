// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
// SPDX-License-Identifier: Apache-2.0

import AppKit
import LDTXProtos
@testable import LDTXWorkspaceAppletUI
import SwiftUI
import Testing

extension AppUIComponentTestSuite {
  @Suite("UCT-1008: SwiftUI visibility", .serialized) @MainActor
  struct UCT1008VideoLayersEditorIntegrationTestSuite {
    @Test func hideEditsRemainLiveDuringOutput() throws {
      let fixture = VideoLayersTestFixture()
      let row = try #require(fixture.editor.rows[1])
      fixture.state.isOutputActive = true
      row.onSetHidden(true)
      #expect(fixture.editor.preferences.videoLayerHidden[1] == true)
      #expect(row.isHidden)
      row.onSetHidden(false)
      #expect(fixture.editor.preferences.videoLayerHidden[1] == false)
      fixture.state.workspaceDefinition.programs = []
      row.onSetHidden(true)
      #expect(
        fixture.state.workspacePreferences.landscapeProgramPreferences[100]?.videoLayerHidden[1]
          == false)
    }
  }
}
