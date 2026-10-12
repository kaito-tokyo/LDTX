// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
//
// SPDX-License-Identifier: Apache-2.0

import AppKit
import SwiftUI

public struct WorkspaceScene: Scene {
  public init() {}

  public var body: some Scene {
    documentScene.commands {
      CommandGroup(replacing: .newItem) {
        Button("New Workspace") {
          do {
            let document = try NSDocumentController.shared.openUntitledDocumentAndDisplay(false)
            (document as? WorkspaceDocument)?.saveAfterCreation()
          } catch { NSDocumentController.shared.presentError(error) }
        }
        .keyboardShortcut("n")
      }
    }
  }

  @SceneBuilder private var documentScene: some Scene {}
}
