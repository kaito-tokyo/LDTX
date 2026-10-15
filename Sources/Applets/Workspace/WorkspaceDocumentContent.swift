// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
//
// SPDX-License-Identifier: Apache-2.0

import SwiftUI

public struct WorkspaceDocumentContent: View {
  let document: WorkspaceDocument

  public init(document: WorkspaceDocument) { self.document = document }

  public var body: some View {
    WorkspaceViewControllerRepresentation(document: document)
      .focusedSceneValue(\.workspaceUndoDisabled, true)
  }
}

private struct WorkspaceUndoDisabledKey: FocusedValueKey {
  typealias Value = Bool
}

extension FocusedValues {
  var workspaceUndoDisabled: Bool? {
    get { self[WorkspaceUndoDisabledKey.self] }
    set { self[WorkspaceUndoDisabledKey.self] = newValue }
  }
}

public struct WorkspaceCommands: Commands {
  @FocusedValue(\.workspaceUndoDisabled) private var isUndoDisabled

  public init() {}

  public var body: some Commands {
    if isUndoDisabled == true {
      CommandGroup(replacing: .undoRedo) {
        Button("Undo") {}
          .keyboardShortcut("z", modifiers: .command)
          .disabled(true)
        Button("Redo") {}
          .keyboardShortcut("z", modifiers: [.command, .shift])
          .disabled(true)
      }
    }
  }
}
