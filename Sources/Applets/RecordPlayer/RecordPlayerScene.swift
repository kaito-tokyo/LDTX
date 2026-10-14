// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
//
// SPDX-License-Identifier: Apache-2.0

import SwiftUI

public struct RecordPlayerScene: Scene {
  public init() {}

  public var body: some Scene {
    DocumentGroup(allowCreating: false) { (document: RecordPlayerDocument) in
      RecordPlayerDocumentContent(document: document)
    } makeDocument: { configuration, _ in
      RecordPlayerDocument(configuration: configuration)
    }
    .defaultSize(width: 960, height: 600)
    .windowToolbarStyle(.unified)
  }
}

private struct RecordPlayerDocumentContent: View {
  let document: RecordPlayerDocument
  @Environment(\.dismiss) private var dismiss

  var body: some View {
    LDTXRecordPlayerView(model: document.model, document: document, requestClose: { dismiss() })
  }
}

private struct RecordPlayerInspectorKey: FocusedValueKey {
  typealias Value = Binding<Bool>
}

extension FocusedValues {
  var recordPlayerInspector: Binding<Bool>? {
    get { self[RecordPlayerInspectorKey.self] }
    set { self[RecordPlayerInspectorKey.self] = newValue }
  }
}

public struct RecordPlayerCommands: Commands {
  @FocusedBinding(\.recordPlayerInspector) private var isInspectorPresented

  public init() {}

  public var body: some Commands {
    CommandGroup(after: .sidebar) {
      Button("Toggle Inspector") { isInspectorPresented?.toggle() }
        .disabled(isInspectorPresented == nil)
    }
  }
}
