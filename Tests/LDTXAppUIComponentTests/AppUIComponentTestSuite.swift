// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
// SPDX-License-Identifier: Apache-2.0

import AppKit
import LDTXRecordPlayerApplet
import LDTXRecording
import LDTXWorkspaceAppletController
import Testing

@Suite(.serialized)
@MainActor
struct AppUIComponentTestSuite {
  init() { _ = UIComponentTestEnvironment.documentController }

}

@MainActor
enum UIComponentTestEnvironment {
  static let documentController = UIComponentDocumentController()
}

@MainActor
final class UIComponentDocumentController: NSDocumentController {
  override func documentClass(forType typeName: String) -> AnyClass? {
    switch typeName {
    case "tokyo.kaito.ldtx.workspace": WorkspaceDocument.self
    case RecordPlayerDocument.typeName, RecordingPackageInfo.legacyTypeIdentifier:
      RecordPlayerDocument.self
    default: super.documentClass(forType: typeName)
    }
  }

  override func typeForContents(of url: URL) throws -> String {
    switch url.pathExtension {
    case "ldtxworkspace": "tokyo.kaito.ldtx.workspace"
    case "ldtxrecord": RecordPlayerDocument.typeName
    default: try super.typeForContents(of: url)
    }
  }
}
