// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
// SPDX-License-Identifier: Apache-2.0

import AppKit
import LDTXCorelibs
@testable import LDTXWorkspaceAppletUI
import SwiftUI
import Testing

extension AppUIComponentTestSuite.Shard2 {
  @Suite("SwiftUI transform drafts", .serialized) @MainActor
  struct DraftVideoLayersEditorIntegrationTestSuite {
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
        (saved.translationX ?? .init()).double,
        (saved.translationY ?? .init()).double,
        (saved.scaleX ?? .init()).double,
        (saved.scaleY ?? .init()).double,
      ]
      let original = [
        (before.translationX ?? .init()).double,
        (before.translationY ?? .init()).double,
        (before.scaleX ?? .init()).double,
        (before.scaleY ?? .init()).double,
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
      #expect(
        (row.transform.translationX ?? .init()).double
          == 0)
      #expect(
        fixture.editor.preferences.videoLayerTransforms[1]?.scaleY?.double == 0.5)
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
      #expect(
        (row.transform.scaleX ?? .init()).double == 1)
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
      #expect(
        (row.transform.translationX ?? .init()).double
          == 0)
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
      #expect(
        workspaceDescendants(window.contentView!)
          .compactMap { $0 as? NSTextField }.filter(\.isEditable).isEmpty)
      fixture.editor.selectedLayerID = 1
      await settleWorkspaceToolbar(window)
      let fields = workspaceDescendants(window.contentView!)
        .compactMap { $0 as? NSTextField }.filter(\.isEditable)
      // A VFX Source shows position, scale, and four crop fields.
      #expect(fields.count == 8)
      let field = try #require(fields.first { $0.placeholderString == "Pos X" })
      try editWorkspaceField(field, text: "960", window: window)
      await settleWorkspaceToolbar(window)
      #expect(
        fixture.editor.preferences.videoLayerTransforms[1]?.translationX?.double == 0.5)
    }

    struct CropInput: Sendable, Codable {
      let field: Int
      let input: String
      /// The saved inset, or nil when the preferences stay unchanged.
      let expected: Double?
    }

    @Test(
      "LUB-1048: Crop percentages commit as insets of the content",
      arguments: [
        CropInput(field: 4, input: "12.5", expected: 0.125),
        CropInput(field: 5, input: "0", expected: nil),
        CropInput(field: 6, input: "100", expected: 1),
        CropInput(field: 7, input: "101", expected: nil),
        CropInput(field: 7, input: "-1", expected: nil),
        CropInput(field: 7, input: "1/3", expected: nil),
      ])
    func cropPercentagesCommitAsInsets(_ data: CropInput) throws {
      let fixture = VideoLayersTestFixture()
      let row = try #require(fixture.editor.rows[1])
      #expect(row.supportsCrop)
      let before = fixture.state.workspacePreferences
      row.edit(data.input, at: data.field)
      let saved = fixture.editor.preferences.videoLayerTransforms[1]
      let insets = [saved?.topInset, saved?.rightInset, saved?.bottomInset, saved?.leftInset]
      if let expected = data.expected {
        let inset = try #require(insets[data.field - 4])
        #expect(inset.double == expected)
        for offset in 0..<4 where offset != data.field - 4 {
          #expect(insets[offset] == nil)
        }
        #expect(row.strings[data.field] == data.input)
      } else {
        #expect(fixture.state.workspacePreferences == before)
        #expect(row.strings[data.field] == data.input)
      }
    }

    @Test("LUB-1048: Only VFX Sources expose crop controls")
    func onlyVFXSourcesExposeCrop() throws {
      let fixture = VideoLayersTestFixture()
      fixture.state.editWorkspace(undoManager: nil) { workspace in
        workspace.definition.videoComponents[1].videoComponent = .clock(
          .with {
            $0.internalID = 2
            $0.displayName = "Clock"
          })
        workspace.definition.videoComponents[2].videoComponent = .dynamicText(
          .with {
            $0.internalID = 3
            $0.displayName = "Text"
          })
      }
      fixture.editor.synchronizeRows()
      #expect(fixture.editor.rows[1]?.supportsCrop == true)
      #expect(fixture.editor.rows[2]?.supportsCrop == false)
      #expect(fixture.editor.rows[3]?.supportsCrop == false)
      #expect(fixture.editor.rows[2]?.supportsPlacement == true)
    }
  }
}
