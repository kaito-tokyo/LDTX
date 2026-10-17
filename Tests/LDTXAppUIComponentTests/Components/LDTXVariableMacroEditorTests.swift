// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
// SPDX-License-Identifier: Apache-2.0

import AppKit
import LDTXProtos
import LDTXRichText
@testable import LDTXVariableMacro
@testable import LDTXWorkspaceAppletController
@testable import LDTXWorkspaceAppletService
import LDTXWorkspaceAppletUI
import SwiftUI
import Testing

extension AppUIComponentTestSuite {
  @MainActor @Suite(.serialized)
  struct LDTXVariableMacroEditorIntegrationTestSuite {
    let first = LDTXVariableReference(id: "11", sel: "text")
    let second = LDTXVariableReference(id: "22", sel: "label")
    init() { _ = UIComponentTestEnvironment.documentController }

    func editor(document: LDTXRichTextDocument) -> MacroTextView {
      let editor = MacroTextView(frame: .zero, usingTextLayoutManager: true)
      editor.update(
        document: document, keys: [first, second],
        names: [first: "試合タイマー · text", second: "シーン · label"], isEnabled: true)
      return editor
    }

    @Test func controllerContainsOnlyTextEditorWithNativeVariableMenu() throws {
      let controller = LDTXVariableMacroEditorController()
      controller.loadViewIfNeeded()
      let window = NSWindow(contentViewController: controller)
      defer { window.close() }
      window.makeFirstResponder(controller.editor)
      controller.editor.update(
        document: richDocument([]), keys: [first, second],
        names: [first: "Timer", second: "Scene"], isEnabled: true)
      #expect(controller.view is NSScrollView)
      let event = try #require(
        NSEvent.mouseEvent(
          with: .rightMouseDown, location: .zero, modifierFlags: [], timestamp: 0,
          windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1,
          pressure: 0))
      let menu = try #require(controller.editor.menu(for: event))
      let variables = try #require(menu.items.first { $0.title == "Insert Variable" }?.submenu)
      let item = try #require(variables.items.first)
      #expect(NSApp.sendAction(try #require(item.action), to: item.target, from: item))
      #expect(try richExpressions(controller.editor.document) == [.variable(first)])
      controller.editor.setSelectedRange(NSRange(location: 0, length: 1))
      #expect(controller.editor.selectedRange() == NSRange(location: 0, length: 1))
      let replacement = variables.items[1]
      #expect(
        NSApp.sendAction(
          try #require(replacement.action), to: replacement.target, from: replacement))
      #expect(try richExpressions(controller.editor.document) == [.variable(second)])
      controller.editor.update(
        document: try controller.editor.document, keys: [first, second],
        names: controller.editor.names, isEnabled: false)
      #expect(!controller.editor.isEditable)
      let disabledMenu = try #require(controller.editor.menu(for: event))
      #expect(!disabledMenu.items.contains { $0.title == "Insert Variable" })
    }

    @Test func repeatedEditingKeepsAtomicChipsAndModelInSync() throws {
      let editor = editor(document: richDocument([]))
      for _ in 0..<10 {
        editor.update(
          document: richDocument([.text("前 🙂 後")]), keys: [first, second],
          names: editor.names,
          isEnabled: true)
        editor.setSelectedRange(NSRange(location: 5, length: 0))
        editor.insertVariable(first)
        #expect(
          try richExpressions(editor.document) == [.text("前 🙂 "), .variable(first), .text("後")])
        editor.setSelectedRange(NSRange(location: 5, length: 1))
        editor.insertVariable(second)
        #expect(try richExpressions(editor.document)[1] == .variable(second))
        editor.insertText("R", replacementRange: NSRange(location: 6, length: 0))
        editor.insertText("L", replacementRange: NSRange(location: 5, length: 0))
        let attachment =
          editor.attributedString().attribute(.attachment, at: 6, effectiveRange: nil)
          as? NSTextAttachment
        #expect(attachment?.attachmentCell != nil)
        #expect(attachment?.allowsTextAttachmentView == false)
        #expect(
          try richExpressions(editor.document) == [.text("前 🙂 L"), .variable(second), .text("R後")])
        editor.insertText("", replacementRange: NSRange(location: 6, length: 1))
        #expect(try richExpressions(editor.document) == [.text("前 🙂 LR後")])
        #expect(editor.textLayoutManager != nil)
      }
    }

    @Test func clipboardPreservesReferencesInternallyAndKeepsExternalTokensLiteral() throws {
      let original = richDocument([
        .text("前  "), .variable(first), .text("\n後"),
      ])
      let editor = editor(document: original)
      let board = NSPasteboard.withUniqueName()
      defer { board.releaseGlobally() }
      editor.setSelectedRange(NSRange(location: 0, length: editor.string.utf16.count))
      #expect(editor.writeSelection(to: board, types: editor.writablePasteboardTypes))
      #expect(board.data(forType: .rtfd) != nil)
      #expect(try board.string(forType: .string) == original.plainText())
      #expect(editor.readSelection(from: board))
      #expect(try editor.document == original)
      board.clearContents()
      board.setString("日本語 {{visions/11/text}}  🙂", forType: .string)
      editor.setSelectedRange(NSRange(location: 0, length: editor.string.utf16.count))
      #expect(editor.readSelection(from: board))
      #expect(try richExpressions(editor.document) == [.text("日本語 {{visions/11/text}}  🙂")])
    }

    @Test func formattingPublishesAndPresentationChangesDoNotRewriteTheDocument() throws {
      var reference = first
      reference.body = "arbitrary body\nvalue"
      let original = richDocument([.text("Text"), .variable(reference)])
      let editor = editor(document: original)
      var changes: [LDTXRichTextDocument] = []
      editor.onDocumentChange = { changes.append($0) }
      editor.update(
        document: original, keys: [first, second], names: [first: "Renamed"], isEnabled: true)
      #expect(changes.isEmpty)
      editor.textStorage?.addAttribute(
        .font, value: NSFont.boldSystemFont(ofSize: 32), range: NSRange(location: 0, length: 4))
      #expect(changes.count == 1)
      let snapshot = try #require(changes.last)
      #expect(snapshot != original)
      editor.update(
        document: snapshot, keys: [first, second], names: editor.names, isEnabled: true)
      #expect(changes.count == 1)
      editor.setSelectedRange(NSRange(location: 4, length: 1))
      editor.insertVariable(second)
      let text = try editor.document.attributedString()
      let attachment = try #require(
        text.attribute(.attachment, at: 4, effectiveRange: nil) as? NSTextAttachment)
      let replacement = try LDTXVariableReference(attachment: attachment)
      #expect(replacement.id == second.id)
      #expect(replacement.body == reference.body)
    }

    @Test func invalidPasteKeepsContentAndReportsError() throws {
      let original = richDocument([.text("Keep me")])
      let editor = editor(document: original)
      var failure: Error?
      editor.onError = { failure = $0 }
      let board = NSPasteboard.withUniqueName()
      defer { board.releaseGlobally() }
      let wrapper = FileWrapper(regularFileWithContents: Data("foreign file".utf8))
      wrapper.preferredFilename = "file.txt"
      let text = NSAttributedString(attachment: NSTextAttachment(fileWrapper: wrapper))
      let data = try text.data(
        from: NSRange(location: 0, length: text.length),
        documentAttributes: [.documentType: NSAttributedString.DocumentType.rtfd])
      board.setData(data, forType: .rtfd)
      editor.selectAll(nil)
      #expect(!editor.readSelection(from: board, type: .rtfd))
      #expect(failure != nil)
      #expect(try editor.document == original)
    }

    @Test func exportFailureKeepsDraftAndDoesNotPublishLossyData() {
      let original = richDocument([.text("Keep me")])
      let editor = editor(document: original)
      var changes = 0
      var failure: Error?
      editor.onDocumentChange = { _ in changes += 1 }
      editor.onError = { failure = $0 }
      editor.insertText(
        "\u{0}", replacementRange: NSRange(location: editor.string.utf16.count, length: 0))
      #expect(editor.string.hasSuffix("\u{0}"))
      #expect(changes == 0)
      #expect(failure != nil)
    }

    @Test func markedTextBlocksVariableInsertionAndExternalEchoDoesNotReplaceAttachments() throws {
      let document = richDocument([.variable(first)])
      let editor = editor(document: document)
      let attachment =
        editor.attributedString().attribute(.attachment, at: 0, effectiveRange: nil)
        as? NSTextAttachment
      editor.update(
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
      #expect(try richExpressions(editor.document).last == .variable(second))
    }

    @Test func hostedChipsSurviveUndoRedoAndRenderAfterRepeatedUpdates() async throws {
      let document = WorkspaceDocument()
      let state = document.stateService
      let original = richDocument([
        .text("現在のシーン："), .variable(second), .text("\n残り時間："), .variable(first),
      ])
      state.workspaceDefinition.videoComponents = [
        .with {
          $0.dynamicText.internalID = 33
          $0.dynamicText.rtfdDocument = original.rtfd
        }
      ]
      let connection = WorkspaceDocumentConnection(document: document)
      let root = HostedEditor(state: state, keys: [first, second])
      let window = hostWorkspaceView(root.padding(16), width: 480, height: 260)
      defer { window.close() }
      await settleWorkspaceToolbar(window)
      let native = try #require(
        workspaceDescendants(window.contentView!).compactMap { $0 as? MacroTextView }.first)
      window.makeFirstResponder(native)
      #expect(try #require(native.enclosingScrollView).bounds.height >= 120)
      let undo = try #require(window.undoManager)
      undo.groupsByEvent = false
      connection.setUndoManager(undo)
      #expect(!native.allowsUndo)
      native.setSelectedRange(NSRange(location: native.string.utf16.count, length: 0))
      undo.beginUndoGrouping()
      native.insertVariable(second)
      native.insertText(
        "追記🙂", replacementRange: NSRange(location: native.string.utf16.count, length: 0))
      connection.recordEdits()
      undo.endUndoGrouping()
      await settleWorkspaceToolbar(window)
      let after = try native.document
      #expect(try after.plainText().hasSuffix("追記🙂"))
      undo.beginUndoGrouping()
      state.workspaceDefinition.displayName = "Renamed"
      connection.recordEdits()
      undo.endUndoGrouping()
      undo.undo()
      await settleWorkspaceToolbar(window)
      #expect(state.workspaceDefinition.displayName == "Untitled")
      #expect(try native.document == after)
      #expect(native.tryToPerform(NSSelectorFromString("undo:"), with: nil))
      await settleWorkspaceToolbar(window)
      #expect(try native.document == original)
      #expect(native.tryToPerform(NSSelectorFromString("redo:"), with: nil))
      await settleWorkspaceToolbar(window)
      #expect(try native.document == after)
      #expect(undo.canRedo)
      undo.redo()
      #expect(state.workspaceDefinition.displayName == "Renamed")
      for _ in 0..<10 {
        undo.beginUndoGrouping()
        native.insertText(
          "追記", replacementRange: NSRange(location: native.string.utf16.count, length: 0))
        connection.recordEdits()
        undo.endUndoGrouping()
        native.update(
          document: try native.document, keys: [first, second], names: native.names, isEnabled: true
        )
      }
      await settleWorkspaceToolbar(window)
      #expect(
        try native.document
          == (try LDTXRichTextDocument(
            rtfd: state.workspaceDefinition.videoComponents[0].dynamicText.rtfdDocument)))
      native.update(
        document: richDocument([.text("New document"), .variable(first)]),
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

@MainActor
private struct HostedEditor: View {
  let state: WorkspaceStateService
  let keys: [LDTXVariableReference]

  var body: some View {
    LDTXVariableMacroEditor(
      document: try! LDTXRichTextDocument(
        rtfd: state.workspaceDefinition.videoComponents[0].dynamicText.rtfdDocument),
      keys: keys, name: { $0.sel },
      onDocumentChange: {
        state.workspaceDefinition.videoComponents[0].dynamicText.rtfdDocument = $0.rtfd
      }
    )
    .frame(minHeight: 120)
  }
}

private enum RichTestExpression: Equatable {
  case text(String)
  case variable(LDTXVariableReference)
}

private func richDocument(_ expressions: [RichTestExpression]) -> LDTXRichTextDocument {
  let text = NSMutableAttributedString(string: "")
  for expression in expressions {
    switch expression {
    case .text(let value): text.append(NSAttributedString(string: value))
    case .variable(let reference):
      text.append(NSAttributedString(attachment: try! reference.attachment()))
    }
  }
  return try! LDTXRichTextDocument(text)
}

private func richExpressions(_ document: LDTXRichTextDocument) throws -> [RichTestExpression] {
  let text = try document.attributedString()
  var result: [RichTestExpression] = []
  var error: Error?
  text.enumerateAttributes(in: NSRange(location: 0, length: text.length)) { attributes, range, _ in
    if let attachment = attributes[.attachment] as? NSTextAttachment {
      do { result.append(.variable(try LDTXVariableReference(attachment: attachment))) } catch let
        failure
      { error = failure }
    } else {
      let value = (text.string as NSString).substring(with: range)
      if case .text(let previous)? = result.last {
        result[result.count - 1] = .text(previous + value)
      } else {
        result.append(.text(value))
      }
    }
  }
  if let error { throw error }
  return result
}
