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

    enum TransformField: Int, Sendable, Codable {
      case translationX, translationY, scaleX, scaleY
    }

    struct TransformInput: Sendable, Codable {
      let field: TransformField
      let input: String
      let expectedNumerator: Int32
      let expectedDenominator: UInt32
    }

    @Test(
      "LUB-1048: Representable transform input commits only the selected field",
      arguments: [
        TransformInput(
          field: .translationX, input: "960", expectedNumerator: 960, expectedDenominator: 1920),
        TransformInput(
          field: .translationY, input: "270", expectedNumerator: 270, expectedDenominator: 1080),
        TransformInput(
          field: .scaleX, input: "-1.25", expectedNumerator: -125, expectedDenominator: 100),
        TransformInput(field: .scaleY, input: "2", expectedNumerator: 2, expectedDenominator: 1),
      ])
    func representableTransformInput(_ data: TransformInput) throws {
      let fixture = VideoLayersTestFixture()
      let row = try #require(fixture.editor.rows[1])
      let before = row.transform
      row.edit(data.input, at: data.field.rawValue)
      let saved = try #require(fixture.editor.preferences.videoLayerTransforms[1])
      let values = [
        saved.translationX.double, saved.translationY.double, saved.scaleX.double,
        saved.scaleY.double,
      ]
      let original = [
        before.translationX.double, before.translationY.double, before.scaleX.double,
        before.scaleY.double,
      ]
      #expect(
        values[data.field.rawValue] == Double(data.expectedNumerator)
          / Double(data.expectedDenominator))
      for field in 0..<4 where field != data.field.rawValue {
        #expect(values[field] == original[field])
      }
    }

    @Test("LUB-1048: Editing another transform field preserves an incomplete draft")
    func editingAnotherFieldPreservesDraft() throws {
      let fixture = VideoLayersTestFixture()
      let row = try #require(fixture.editor.rows[1])
      row.edit("-", at: 0)
      row.edit("0.5", at: 3)
      fixture.editor.synchronizeRows()
      #expect(fixture.editor.rows[1] === row)
      #expect(row.strings[0] == "-")
      #expect(row.hasLocalTextChanges)
      #expect(row.transform.translationX.double == 0)
      #expect(fixture.editor.preferences.videoLayerTransforms[1]?.scaleY.double == 0.5)
    }

    @Test(
      "LUB-1048: Invalid scales remain local",
      arguments: ["-", "１２", "inf", "1e100", "7/9", "0.12345678901", "2147483648"])
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

    @Test("LUB-1048: Positions require integer pixels", arguments: ["100.125", "1/3"])
    func positionsRequireIntegerPixels(text: String) throws {
      let fixture = VideoLayersTestFixture()
      let row = try #require(fixture.editor.rows[1])
      row.edit(text, at: 0)
      #expect(row.hasLocalTextChanges)
      #expect(row.transform.translationX.double == 0)
    }

    @Test("LUB-1048: Stale callbacks do not edit removed layers")
    func staleCallbacksDoNotEditRemovedLayers() throws {
      let fixture = VideoLayersTestFixture()
      let row = try #require(fixture.editor.rows[1])
      fixture.update(ids: [2, 3])
      let before = fixture.state.workspacePreferences
      row.edit("960", at: 0)
      row.onSetHidden(true, nil)
      #expect(fixture.state.workspacePreferences == before)
      #expect(row.strings[0] == "960")
      fixture.update(ids: [1, 2, 3])
      let readded = fixture.state.workspacePreferences
      row.edit("192", at: 0)
      row.onSetHidden(true, nil)
      #expect(fixture.state.workspacePreferences == readded)
    }

    @Test("LUB-1048: Callbacks do not retain editor or rows")
    func callbacksDoNotRetainEditorOrRows() {
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
      retained?.onSetHidden(true, nil)
    }

    @Test("LUB-1048: Hosted fields write without return") func hostedFieldsWriteWithoutReturn()
      async throws
    {
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
