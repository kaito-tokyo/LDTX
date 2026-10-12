// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
//
// SPDX-License-Identifier: Apache-2.0

import SwiftUI

public struct RecordPlayerScene: Scene {
  public init() {}

  public var body: some Scene {
    documentScene.commands { RecordPlayerCommands() }
  }

  @SceneBuilder private var documentScene: some Scene {}
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

private struct RecordPlayerCommands: Commands {
  @FocusedBinding(\.recordPlayerInspector) private var isInspectorPresented

  var body: some Commands {
    CommandGroup(after: .sidebar) {
      Button("Toggle Inspector") { isInspectorPresented?.toggle() }
        .disabled(isInspectorPresented == nil)
    }
  }
}
