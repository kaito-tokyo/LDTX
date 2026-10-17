// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
// SPDX-License-Identifier: Apache-2.0

import AppKit
import LDTXVariableStore
import Observation
import SwiftUI

public struct VariableMacroEditor: View {
  @Binding private var document: VariableMacroDocument
  private let keys: [VariableKey]
  private let name: (VariableKey) -> String
  @State private var controller = MacroEditorController()
  @Environment(\.isEnabled) private var isEnabled

  public init(
    document: Binding<VariableMacroDocument>, keys: [VariableKey],
    name: @escaping (VariableKey) -> String
  ) {
    _document = document
    self.keys = keys
    self.name = name
  }

  public var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      MacroEditorBridge(
        document: $document, controller: controller, keys: keys,
        names: Dictionary(uniqueKeysWithValues: keys.map { ($0, name($0)) }), isEnabled: isEnabled
      )
      .frame(minHeight: 120)
      Menu(controller.selectedVariable == nil ? "Insert Variable" : "Replace Selected Variable") {
        ForEach(keys) { key in
          Button(name(key)) { controller.editor?.insertVariable(key) }
        }
      }
      .disabled(keys.isEmpty || controller.isComposing)
      if let key = controller.selectedVariable {
        Text("Selected variable: \(name(key))")
          .font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
      }
      if keys.isEmpty {
        Text("Add a Vision to make variables available.")
          .font(.caption).foregroundStyle(.secondary)
      }
    }
  }
}

@MainActor @Observable
final class MacroEditorController {
  @ObservationIgnored weak var editor: MacroTextView?
  var selectedVariable: VariableKey?
  var isComposing = false
}

private struct MacroEditorBridge: NSViewRepresentable {
  @Binding var document: VariableMacroDocument
  let controller: MacroEditorController
  let keys: [VariableKey]
  let names: [VariableKey: String]
  let isEnabled: Bool

  func makeNSView(context: Context) -> NSScrollView {
    let scroll = NSScrollView()
    scroll.hasVerticalScroller = true
    scroll.borderType = .bezelBorder
    let editor = MacroTextView(usingTextLayoutManager: true)
    editor.frame = NSRect(x: 0, y: 0, width: 280, height: 120)
    editor.minSize = NSSize(width: 0, height: 120)
    editor.maxSize = NSSize(
      width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
    editor.isVerticallyResizable = true
    editor.isHorizontallyResizable = false
    editor.autoresizingMask = [.width]
    editor.textContainer?.widthTracksTextView = true
    editor.textContainerInset = NSSize(width: 8, height: 8)
    scroll.documentView = editor
    controller.editor = editor
    updateNSView(scroll, context: context)
    return scroll
  }

  func updateNSView(_ scroll: NSScrollView, context: Context) {
    guard let editor = scroll.documentView as? MacroTextView else { return }
    editor.onDocumentChange = { document = $0 }
    editor.onSelectionChange = { key, composing in
      controller.selectedVariable = key
      controller.isComposing = composing
    }
    editor.configure(document: document, keys: keys, names: names, isEnabled: isEnabled)
  }
}
