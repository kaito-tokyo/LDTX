// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
//
// SPDX-License-Identifier: Apache-2.0

import AppKit
import LDTXRichText
import SwiftUI

/// A rich text editing surface. The caller owns the document and surrounding UI.
public struct LDTXVariableMacroEditor: NSViewControllerRepresentable {
  private let document: LDTXRichTextDocument
  private let keys: [LDTXVariableReference]
  private let name: (LDTXVariableReference) -> String
  private let onDocumentChange: (LDTXRichTextDocument) -> Void
  private let onError: (Error) -> Void
  @Environment(\.isEnabled) private var isEnabled

  public init(
    document: LDTXRichTextDocument, keys: [LDTXVariableReference],
    name: @escaping (LDTXVariableReference) -> String,
    onDocumentChange: @escaping (LDTXRichTextDocument) -> Void,
    onError: @escaping (Error) -> Void = { _ in }
  ) {
    self.document = document
    self.keys = keys
    self.name = name
    self.onDocumentChange = onDocumentChange
    self.onError = onError
  }

  public func makeNSViewController(context: Context) -> LDTXVariableMacroEditorController {
    LDTXVariableMacroEditorController()
  }

  public func updateNSViewController(
    _ controller: LDTXVariableMacroEditorController, context: Context
  ) {
    controller.loadViewIfNeeded()
    controller.editor.onDocumentChange = onDocumentChange
    controller.editor.onError = onError
    controller.editor.update(
      document: document, keys: keys,
      names: Dictionary(uniqueKeysWithValues: keys.map { ($0, name($0)) }), isEnabled: isEnabled)
  }

  public static func dismantleNSViewController(
    _ controller: LDTXVariableMacroEditorController, coordinator: Void
  ) {
    controller.editor.onDocumentChange = { _ in }
    controller.editor.onError = { _ in }
  }
}

@MainActor
public final class LDTXVariableMacroEditorController: NSViewController {
  let editor = MacroTextView(frame: .zero, usingTextLayoutManager: true)

  public override func loadView() {
    let scroll = NSScrollView()
    scroll.hasVerticalScroller = true
    scroll.borderType = .bezelBorder
    editor.frame = NSRect(x: 0, y: 0, width: 280, height: 120)
    editor.minSize = NSSize(width: 0, height: 120)
    editor.maxSize = NSSize(
      width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
    editor.isVerticallyResizable = true
    editor.isHorizontallyResizable = false
    editor.autoresizingMask = [.width]
    editor.textContainer?.widthTracksTextView = true
    editor.textContainerInset = NSSize(width: 8, height: 8)
    editor.setAccessibilityLabel("Dynamic Text macro editor")
    editor.setAccessibilityHelp(
      "Variables are single items. Click a variable to choose a replacement, or select it and use Insert Variable."
    )
    scroll.documentView = editor
    view = scroll
  }
}
