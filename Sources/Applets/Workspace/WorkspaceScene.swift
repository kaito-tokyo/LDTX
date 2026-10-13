// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
//
// SPDX-License-Identifier: Apache-2.0

import SwiftUI

public struct WorkspaceScene: Scene {
  public init() {}

  public var body: some Scene {
    DocumentGroup { (document: WorkspaceDocument) in
      WorkspaceViewControllerRepresentation(document: document)
    } makeDocument: { configuration, _ in
      WorkspaceDocument(configuration: configuration)
    }
    .windowToolbarStyle(.unified)
  }
}
