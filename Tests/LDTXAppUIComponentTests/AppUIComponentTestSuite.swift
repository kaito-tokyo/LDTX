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

  @Test func sharedDocumentControllerResolvesBothDocumentFamilies() throws {
    let controller = UIComponentTestEnvironment.documentController
    #expect(NSDocumentController.shared === controller)
    #expect(
      controller.documentClass(forType: "tokyo.kaito.ldtx.workspace") === WorkspaceDocument.self)
    #expect(
      controller.documentClass(forType: RecordPlayerDocument.typeName) === RecordPlayerDocument.self
    )
    #expect(
      controller.documentClass(forType: RecordingPackageInfo.legacyTypeIdentifier)
        === RecordPlayerDocument.self)
    #expect(
      try controller.typeForContents(of: URL(fileURLWithPath: "/tmp/Test.ldtxworkspace"))
        == "tokyo.kaito.ldtx.workspace")
    #expect(
      try controller.typeForContents(of: URL(fileURLWithPath: "/tmp/Test.ldtxrecord"))
        == RecordPlayerDocument.typeName)
  }
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
