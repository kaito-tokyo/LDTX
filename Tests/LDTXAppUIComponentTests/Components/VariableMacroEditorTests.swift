// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
// SPDX-License-Identifier: Apache-2.0

import AppKit
import LDTXProtos
@testable import LDTXVariableMacro
import LDTXVariableStore
@testable import LDTXWorkspaceAppletController
@testable import LDTXWorkspaceAppletService
import SwiftUI
import Testing

extension AppUIComponentTestSuite {
  @MainActor @Suite(.serialized)
  struct VariableMacroEditorIntegrationTestSuite {
    let first = VariableKey(visionID: 11, item: .text)
    let second = VariableKey(visionID: 22, item: .label)
    init() { _ = UIComponentTestEnvironment.documentController }

    func editor(document: VariableMacroDocument) -> MacroTextView {
      let editor = MacroTextView(usingTextLayoutManager: true)
      editor.configure(
        document: document, keys: [first, second],
        names: [first: "試合タイマー · text", second: "シーン · label"], isEnabled: true)
      return editor
    }

    @Test func repeatedEditingKeepsAtomicChipsAndModelInSync() {
      let editor = editor(document: .init())
      for _ in 0..<10 {
        editor.configure(
          document: .init(segments: [.text("前 🙂 後")]), keys: [first, second], names: editor.names,
          isEnabled: true)
        editor.setSelectedRange(NSRange(location: 5, length: 0))
        editor.insertVariable(first)
        #expect(editor.document.segments == [.text("前 🙂 "), .variable(first), .text("後")])
        editor.setSelectedRange(NSRange(location: 5, length: 1))
        editor.insertVariable(second)
        #expect(editor.document.segments[1] == .variable(second))
        editor.insertText("R", replacementRange: NSRange(location: 6, length: 0))
        editor.insertText("L", replacementRange: NSRange(location: 5, length: 0))
        let attachment =
          editor.attributedString().attribute(.attachment, at: 6, effectiveRange: nil)
          as? NSTextAttachment
        #expect(attachment?.image != nil)
        #expect(attachment?.allowsTextAttachmentView == false)
        #expect(editor.document.segments == [.text("前 🙂 L"), .variable(second), .text("R後")])
        editor.insertText("", replacementRange: NSRange(location: 6, length: 1))
        #expect(editor.document.segments == [.text("前 🙂 LR後")])
        #expect(editor.textLayoutManager != nil)
      }
    }

    @Test func clipboardPreservesReferencesInternallyAndKeepsExternalTokensLiteral() {
      let original = VariableMacroDocument(segments: [.text("前  "), .variable(first), .text("\n後")])
      let editor = editor(document: original)
      let board = NSPasteboard.withUniqueName()
      defer { board.releaseGlobally() }
      editor.setSelectedRange(NSRange(location: 0, length: editor.string.utf16.count))
      editor.writeSelection(to: board)
      #expect(board.string(forType: .string) == original.plainText)
      editor.paste(from: board)
      #expect(editor.document == original)
      board.clearContents()
      board.setString("日本語 {{visions/11/text}}  🙂", forType: .string)
      editor.setSelectedRange(NSRange(location: 0, length: editor.string.utf16.count))
      editor.paste(from: board)
      #expect(editor.document.segments == [.text("日本語 {{visions/11/text}}  🙂")])
    }

    @Test func markedTextBlocksVariableInsertionAndExternalEchoDoesNotReplaceAttachments() {
      let document = VariableMacroDocument(segments: [.variable(first)])
      let editor = editor(document: document)
      let attachment =
        editor.attributedString().attribute(.attachment, at: 0, effectiveRange: nil)
        as? NSTextAttachment
      editor.configure(
        document: document, keys: [first, second], names: editor.names, isEnabled: true)
      #expect(
        editor.attributedString().attribute(.attachment, at: 0, effectiveRange: nil)
          as? NSTextAttachment === attachment)
      editor.setSelectedRange(NSRange(location: 1, length: 0))
      editor.setMarkedText(
        "にほん", selectedRange: NSRange(location: 3, length: 0),
        replacementRange: NSRange(location: NSNotFound, length: 0))
      let marked = editor.string
      editor.insertVariable(second)
      #expect(editor.string == marked)
      editor.insertText("日本", replacementRange: editor.markedRange())
      editor.insertVariable(second)
      #expect(editor.document.segments.last == .variable(second))
    }

    @Test func hostedChipsSurviveUndoRedoAndRenderAfterRepeatedUpdates() async throws {
      let document = WorkspaceDocument()
      let state = document.stateService
      let original = VariableMacroDocument(segments: [
        .text("現在のシーン："), .variable(second), .text("\n残り時間："), .variable(first),
      ])
      state.workspaceDefinition.videoComponents = [
        .with {
          $0.dynamicText.internalID = 33
          $0.dynamicText.macroDocument = original.xml
        }
      ]
      let connection = WorkspaceDocumentConnection(document: document)
      let root = VariableMacroEditor(
        document: Binding(
          get: {
            try! VariableMacroDocument(
              xml: state.workspaceDefinition.videoComponents[0].dynamicText.macroDocument)
          },
          set: {
            state.workspaceDefinition.videoComponents[0].dynamicText.macroDocument = $0.xml
          }),
        keys: [first, second], name: { $0 == first ? "試合タイマー · text" : "シーン · label" })
      let window = hostWorkspaceView(root.padding(16), width: 480, height: 260)
      defer { window.close() }
      await settleWorkspaceToolbar(window)
      let native = try #require(
        workspaceDescendants(window.contentView!).compactMap { $0 as? MacroTextView }.first)
      window.makeFirstResponder(native)
      let undo = try #require(window.undoManager)
      undo.groupsByEvent = false
      connection.setUndoManager(undo)
      #expect(!native.allowsUndo)
      native.setSelectedRange(NSRange(location: native.string.utf16.count, length: 0))
      undo.beginUndoGrouping()
      native.insertVariable(second)
      native.insertText(
        "追記\u{0}\u{B}", replacementRange: NSRange(location: native.string.utf16.count, length: 0))
      connection.recordEdits()
      undo.endUndoGrouping()
      await settleWorkspaceToolbar(window)
      let after = native.document
      #expect(after.plainText.hasSuffix("追記��"))
      undo.beginUndoGrouping()
      state.workspaceDefinition.displayName = "Renamed"
      connection.recordEdits()
      undo.endUndoGrouping()
      undo.undo()
      await settleWorkspaceToolbar(window)
      #expect(state.workspaceDefinition.displayName == "Untitled")
      #expect(native.document == after)
      #expect(native.tryToPerform(NSSelectorFromString("undo:"), with: nil))
      await settleWorkspaceToolbar(window)
      #expect(native.document == original)
      #expect(native.tryToPerform(NSSelectorFromString("redo:"), with: nil))
      await settleWorkspaceToolbar(window)
      #expect(native.document == after)
      #expect(undo.canRedo)
      undo.redo()
      #expect(state.workspaceDefinition.displayName == "Renamed")
      for _ in 0..<10 {
        undo.beginUndoGrouping()
        native.insertText(
          "追記", replacementRange: NSRange(location: native.string.utf16.count, length: 0))
        connection.recordEdits()
        undo.endUndoGrouping()
        native.configure(
          document: native.document, keys: [first, second], names: native.names, isEnabled: true)
      }
      await settleWorkspaceToolbar(window)
      #expect(
        native.document
          == (try VariableMacroDocument(
            xml: state.workspaceDefinition.videoComponents[0].dynamicText.macroDocument)))
      native.configure(
        document: .init(segments: [.text("New document"), .variable(first)]),
        keys: [first, second], names: native.names, isEnabled: true)
      #expect(undo.canUndo)
      let view = try #require(window.contentView)
      let bitmap = try #require(view.bitmapImageRepForCachingDisplay(in: view.bounds))
      view.cacheDisplay(in: view.bounds, to: bitmap)
      try #require(bitmap.representation(using: .png, properties: [:])).write(
        to: URL(fileURLWithPath: "/tmp/ldtx-macro-editor-preview.png"))
      await connection.shutdown()
    }
  }
}
