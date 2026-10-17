// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
// SPDX-License-Identifier: Apache-2.0

import AppKit
import LDTXProtos
@testable import LDTXWorkspaceAppletUI
import SwiftUI
import Testing

extension AppUIComponentTestSuite {
  @Suite("UCT-1006: SwiftUI transform drafts", .serialized) @MainActor
  struct UCT1006VideoLayersEditorIntegrationTestSuite {
    init() { _ = UIComponentTestEnvironment.documentController }

    @Test func writesRepresentableFieldsAndRetainsIncompleteDrafts() throws {
      let fixture = VideoLayersTestFixture()
      let row = try #require(fixture.editor.rows[1])
      row.edit("960", at: 0)
      row.edit("270", at: 1)
      row.edit("-1.25", at: 2)
      row.edit("2", at: 3)
      let saved = try #require(fixture.editor.preferences.videoLayerTransforms[1])
      #expect(saved.translationX.num == 960 && saved.translationX.den == 1920)
      #expect(saved.translationY.num == 270 && saved.translationY.den == 1080)
      #expect(saved.scaleX.double == -1.25)
      #expect(saved.scaleY.double == 2)
      row.edit("-", at: 0)
      let before = fixture.editor.preferences
      row.edit("0.5", at: 3)
      #expect(row.strings[0] == "-")
      #expect(row.hasLocalTextChanges)
      #expect(
        fixture.editor.preferences.videoLayerTransforms[1]?.translationX == saved.translationX)
      #expect(fixture.editor.preferences.videoLayerTransforms[1]?.scaleY.double == 0.5)
      fixture.editor.synchronizeRows()
      #expect(fixture.editor.rows[1] === row)
      #expect(row.strings[0] == "-")
      #expect(before.videoLayerTransforms[1]?.scaleY.double == 2)
    }

    @Test(arguments: ["-", "１２", "inf", "1e100", "7/9", "0.12345678901", "2147483648"])
    func invalidScalesRemainLocal(text: String) throws {
      let fixture = VideoLayersTestFixture()
      let row = try #require(fixture.editor.rows[1])
      let before = fixture.state.workspacePreferences
      row.edit(text, at: 2)
      #expect(fixture.state.workspacePreferences == before)
      #expect(row.hasLocalTextChanges)
      #expect(row.transform.scaleX.double == 1)
      fixture.update(ids: [3, 1, 2])
      #expect(fixture.editor.rows[1] === row)
      #expect(row.strings[2] == text)
    }

    @Test(arguments: ["100.125", "1/3"])
    func positionsRequireIntegerPixels(text: String) throws {
      let fixture = VideoLayersTestFixture()
      let row = try #require(fixture.editor.rows[1])
      row.edit(text, at: 0)
      #expect(row.hasLocalTextChanges)
      #expect(row.transform.translationX.double == 0)
    }

    @Test func staleCallbacksDoNotEditRemovedLayers() throws {
      let fixture = VideoLayersTestFixture()
      let row = try #require(fixture.editor.rows[1])
      fixture.update(ids: [2, 3])
      let before = fixture.state.workspacePreferences
      row.edit("960", at: 0)
      row.onSetHidden(true)
      #expect(fixture.state.workspacePreferences == before)
      #expect(row.strings[0] == "960")
      fixture.update(ids: [1, 2, 3])
      let readded = fixture.state.workspacePreferences
      row.edit("192", at: 0)
      row.onSetHidden(true)
      #expect(fixture.state.workspacePreferences == readded)
    }

    @Test func callbacksDoNotRetainEditorOrRows() {
      weak var editor: VideoLayersEditorState?
      weak var row: VideoLayersTableRowState?
      var retained: VideoLayersTableRowState?
      autoreleasepool {
        let fixture = VideoLayersTestFixture()
        editor = fixture.editor
        row = fixture.editor.rows[2]
        retained = fixture.editor.rows[1]
      }
      #expect(editor == nil)
      #expect(row == nil)
      retained?.edit("960", at: 0)
      retained?.onSetHidden(true)
    }

    @Test func hostedFieldsWriteWithoutReturn() async throws {
      let fixture = VideoLayersTestFixture(ids: [1])
      let root = VideoLayersEditor(editor: fixture.editor)
      let window = hostWorkspaceView(List { root })
      defer { window.close() }
      await settleWorkspaceToolbar(window)
      let fields = workspaceDescendants(window.contentView!)
        .compactMap { $0 as? NSTextField }.filter(\.isEditable)
      #expect(fields.count == 4)
      let field = try #require(fields.first)
      try editWorkspaceField(field, text: "960", window: window)
      await settleWorkspaceToolbar(window)
      #expect(fixture.editor.preferences.videoLayerTransforms[1]?.translationX.double == 0.5)
    }
  }
}
