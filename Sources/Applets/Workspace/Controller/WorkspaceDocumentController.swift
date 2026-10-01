// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
// SPDX-License-Identifier: Apache-2.0

import AppKit
import LDTXAppInterface
import LDTXRecording
import LDTXWorkspaceAppletUI

@MainActor
public final class WorkspaceDocumentController: NSDocumentController {
  let appletData = WorkspaceAppletData()
  public weak var recordingActivityReporter: (any WorkspaceRecordingActivityReporting)?
  public var openRecording: ((URL) -> Void)?
  public var didShowDocument: (() -> Void)?

  public override var defaultType: String? { "tokyo.kaito.ldtx.workspace" }

  private func configure(_ document: NSDocument) throws -> NSDocument {
    guard let workspace = document as? WorkspaceDocument else { return document }
    workspace.appletData = appletData
    workspace.recordingActivityReporter = recordingActivityReporter
    try workspace.acquirePackageLock()
    return workspace
  }

  public override func makeUntitledDocument(ofType typeName: String) throws -> NSDocument {
    try configure(super.makeUntitledDocument(ofType: typeName))
  }

  public override func makeDocument(withContentsOf url: URL, ofType typeName: String) throws
    -> NSDocument
  {
    try configure(super.makeDocument(withContentsOf: url, ofType: typeName))
  }

  public override func makeDocument(
    for urlOrNil: URL?, withContentsOf contentsURL: URL, ofType typeName: String
  ) throws -> NSDocument {
    try configure(super.makeDocument(for: urlOrNil, withContentsOf: contentsURL, ofType: typeName))
  }

  public override func newDocument(_ sender: Any?) {
    super.newDocument(sender)
    if currentDocument != nil { didShowDocument?() }
  }

  public override func openDocument(
    withContentsOf url: URL, display displayDocument: Bool,
    completionHandler: @escaping (NSDocument?, Bool, Error?) -> Void
  ) {
    if url.pathExtension.lowercased() == RecordingPackage.pathExtension {
      openRecording?(url)
      completionHandler(nil, false, nil)
      return
    }
    super.openDocument(withContentsOf: url, display: displayDocument) {
      [weak self] document, alreadyOpen, error in
      if document != nil && displayDocument { self?.didShowDocument?() }
      completionHandler(document, alreadyOpen, error)
    }
  }
}
