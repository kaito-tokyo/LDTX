// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
// SPDX-License-Identifier: Apache-2.0
import AppKit
import LDTXProtos
import LDTXProtosMacOSExtra
import LDTXRichText
import LDTXWorkspaceAppletModel
@testable import LDTXWorkspaceAppletService
@testable import LDTXWorkspaceAppletUI
import LDTXWorkspaceBundleFormat
import Testing

@MainActor @Suite(.tags(.medium)) struct WorkspaceRichTextIntegrationTestSuite {
  @Test("LUB-1005: Dynamic text projects attributed variable values")
  func dynamicTextProjectsAttributedVariableValues() throws {
    let content = NSMutableAttributedString(
      string: "結果：",
      attributes: [.font: NSFont.boldSystemFont(ofSize: 24), .foregroundColor: NSColor.red])
    content.append(
      NSAttributedString(
        attachment: try LDTXVariableReference(id: "11", sel: "text", body: "ignored()").attachment()
      ))
    var definition = Ldtx_Workspace_V4_WorkspaceDefinitionV4()
    definition.videoComponents = [
      .with {
        $0.dynamicText = .with {
          $0.internalID = 2
          $0.width.set(num: 1, den: 2)
          $0.height.set(num: 1, den: 10)
          $0.rtfdDocument = try! LDTXRichTextDocument(content).rtfd
        }
      }
    ]
    let original = definition
    let values = [LDTXVariableKey(visionID: 11, item: .text): "勝利 <b>literal</b>"]
    let components = WorkspaceV4RenderGraph.componentsByInternalID(
      definition, variableStore: values)
    guard case .clock(let overlay) = components[2] else {
      Issue.record("Missing text overlay")
      return
    }
    let resolved = try LDTXRichTextDocument(rtfd: #require(overlay.resolvedRTFD))
    #expect(try resolved.attributedString().string == "結果：勝利 <b>literal</b>")
    #expect(definition == original)
    #expect(definition.videoComponents[0].canBeVisionInput == false)
    try definition.validateRichTextDocuments()
    definition.videoComponents[0].dynamicText.rtfdDocument = Data("<macro/>".utf8)
    #expect(throws: (any Error).self) { try definition.validateRichTextDocuments() }
  }

  @Test("LUB-1005: New dynamic text contains valid RTFD and bundle preserves bytes")
  func newDynamicTextContainsValidRTFDAndBundlePreservesBytes() throws {
    let component = try WorkspaceResourceFactory.makeDynamicText(id: 33, name: "Text")
    let document = try LDTXRichTextDocument(rtfd: component.dynamicText.rtfdDocument)
    #expect(try document.attributedString().string == "Dynamic Text")
    let workspace = WorkspaceV4Bundle(
      definition: .with { $0.videoComponents = [component] }, preferences: .init())
    let url = FileManager.default.temporaryDirectory.appendingPathComponent(
      UUID().uuidString + ".ldtxworkspace")
    defer { try? FileManager.default.removeItem(at: url) }
    try WorkspaceBundleWriterV4().write(workspace, to: url)
    let restored = try WorkspaceBundleReaderV4(at: url).read()
    #expect(restored.definition.videoComponents[0].dynamicText.rtfdDocument == document.rtfd)
    try restored.definition.validateRichTextDocuments()
  }
}
