// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
// SPDX-License-Identifier: Apache-2.0

import AppKit
import LDTXWorkspaceAppletController
import LDTXWorkspaceAppletUI

@MainActor
final class LDTXDocumentController: NSDocumentController {
  let appletData = WorkspaceAppletData()

  override var defaultType: String? { "tokyo.kaito.ldtx.workspace" }

  private func configure(_ document: NSDocument) throws -> NSDocument {
    guard let workspace = document as? WorkspaceDocument else { return document }
    workspace.appletData = appletData
    try workspace.acquirePackageLock()
    return workspace
  }

  override func makeUntitledDocument(ofType typeName: String) throws -> NSDocument {
    try configure(super.makeUntitledDocument(ofType: typeName))
  }

  override func makeDocument(withContentsOf url: URL, ofType typeName: String) throws
    -> NSDocument
  {
    try configure(super.makeDocument(withContentsOf: url, ofType: typeName))
  }

  override func makeDocument(
    for urlOrNil: URL?, withContentsOf contentsURL: URL, ofType typeName: String
  ) throws -> NSDocument {
    try configure(super.makeDocument(for: urlOrNil, withContentsOf: contentsURL, ofType: typeName))
  }
}
