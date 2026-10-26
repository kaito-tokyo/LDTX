// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
// SPDX-License-Identifier: Apache-2.0

import Foundation
import LDTXCorelibs
import Testing

@Suite
struct WorkspaceBundleWriterIntegrationTestSuite {
  @Test("LUB-1002: Imports clock without font size and discards reserved geometry")
  func importsClockWithoutFontSizeAndDiscardsReservedGeometry() throws {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: url) }
    let workspace = WorkspaceV4Bundle(
      definitionExternalID: WorkspaceBundleWriterV4.makeExternalID().uuidString.lowercased(),
      preferencesExternalID: WorkspaceBundleWriterV4.makeExternalID().uuidString.lowercased(),
      definition: .init(), preferences: .init())
    try WorkspaceBundleWriterV4().write(workspace, to: url)
    let definitionURL = url.appendingPathComponent("definition.pb")
    var envelope = try Ldtx_Envelope_WorkspaceDefinitionEnvelope(
      serializedBytes: Data(contentsOf: definitionURL))
    let legacy = Data([0x1a, 0x04, 0x08, 0x02, 0x10, 0x0c, 0x22, 0x04, 0x08, 0x04, 0x10, 0x36])
    var clock = try Ldtx_Workspace_V4_ClockComponent(serializedBytes: legacy)
    clock.internalID = 1
    clock.displayName = "Legacy Clock"
    envelope.workspaceDefinition = .workspaceDefinitionV4(
      .with { $0.videoComponents = [.with { $0.videoComponent = .clock(clock) }] })
    let bytes = try envelope.serializedData()
    try bytes.write(to: definitionURL)
    let imported = try WorkspaceBundleReaderV4(at: url).read()
    guard case .clock(let result) = imported.definition.videoComponents[0].videoComponent else {
      Issue.record("Expected clock")
      return
    }
    #expect(result.fontSize == nil)
    #expect(result == clock)
    #expect(try Data(contentsOf: definitionURL) == bytes)
    try WorkspaceBundleWriterV4().write(imported, to: url)
    #expect(try WorkspaceBundleReaderV4(at: url).read().definition == imported.definition)
  }

  private struct Metadata: Codable {
    var packageType: String
    var workspaceVersion: Int
    var workspaceBundleVersion: String
    var customMetadata: String?

    enum CodingKeys: String, CodingKey {
      case packageType = "CFBundlePackageType"
      case workspaceVersion = "LDTXWorkspaceVersion"
      case workspaceBundleVersion = "LDTXWorkspaceBundleVersion"
      case customMetadata = "CustomMetadata"
    }
  }

  @Test("LUB-1002: Preserves resources and envelope identifiers")
  func preservesResourcesAndEnvelopeIdentifiers() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let original = root.appendingPathComponent("Original.ldtxworkspace")
    let snapshot = WorkspaceV4Bundle(
      definitionExternalID: WorkspaceBundleWriterV4.makeExternalID().uuidString.lowercased(),
      preferencesExternalID: WorkspaceBundleWriterV4.makeExternalID().uuidString.lowercased(),
      definition: .init(), preferences: .init())
    try WorkspaceBundleWriterV4().write(snapshot, to: original)
    let infoURL = original.appendingPathComponent("Info.plist")
    let decoder = PropertyListDecoder()
    var info = try decoder.decode(Metadata.self, from: Data(contentsOf: infoURL))
    info.customMetadata = "Preserved"
    let encoder = PropertyListEncoder()
    encoder.outputFormat = .xml
    try encoder.encode(info).write(to: infoURL)
    let resourceURL = original.appendingPathComponent("Resources/image.bin")
    try FileManager.default.createDirectory(
      at: resourceURL.deletingLastPathComponent(), withIntermediateDirectories: true)
    let resource = Data([0, 1, 2, 255])
    try resource.write(to: resourceURL)
    var changed = snapshot
    changed.definition.displayName = "Edited"
    try WorkspaceBundleWriterV4().write(changed, to: original)
    let reloaded = try WorkspaceBundleReaderV4(at: original).read()
    let copiedInfo = try decoder.decode(Metadata.self, from: Data(contentsOf: infoURL))
    #expect(copiedInfo.customMetadata == "Preserved")
    #expect(copiedInfo.packageType == "BNDL")
    #expect(copiedInfo.workspaceVersion == 4)
    #expect(copiedInfo.workspaceBundleVersion == "4.0")
    #expect(reloaded.definition.displayName == "Edited")
    #expect(reloaded.definitionExternalID == snapshot.definitionExternalID)
    #expect(reloaded.preferencesExternalID == snapshot.preferencesExternalID)
    #expect(
      try Data(contentsOf: original.appendingPathComponent("Resources/image.bin")) == resource)
  }

  @Test("LUB-1002: Partial save leaves other files untouched and retries after failure")
  func partialSaveLeavesOtherFilesUntouchedAndRetriesAfterFailure() throws {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: url) }
    var workspace = WorkspaceV4Bundle(
      definitionExternalID: WorkspaceBundleWriterV4.makeExternalID().uuidString.lowercased(),
      preferencesExternalID: WorkspaceBundleWriterV4.makeExternalID().uuidString.lowercased(),
      definition: .init(), preferences: .init())
    try WorkspaceBundleWriterV4().write(workspace, to: url)
    let info = url.appendingPathComponent("Info.plist")
    let resource = url.appendingPathComponent("unknown.bin")
    try Data("Resource".utf8).write(to: resource)
    let oldInfo = try Data(contentsOf: info)
    let oldResourceAttributes = try FileManager.default.attributesOfItem(atPath: resource.path)
    let preferences = url.appendingPathComponent("preferences.pb")
    let oldPreferences = try Data(contentsOf: preferences)
    try FileManager.default.removeItem(at: preferences)
    try FileManager.default.createDirectory(at: preferences, withIntermediateDirectories: false)
    workspace.definition.displayName = "Updated"
    #expect(throws: (any Error).self) { try WorkspaceBundleWriterV4().write(workspace, to: url) }
    #expect(try Data(contentsOf: info) == oldInfo)
    #expect(try Data(contentsOf: resource) == Data("Resource".utf8))
    #expect(
      try FileManager.default.attributesOfItem(atPath: resource.path)[.systemFileNumber]
        as? NSNumber
        == oldResourceAttributes[.systemFileNumber] as? NSNumber)
    try FileManager.default.removeItem(at: preferences)
    try oldPreferences.write(to: preferences)
    try WorkspaceBundleWriterV4().write(workspace, to: url)
    let saved = try WorkspaceBundleReaderV4(at: url).read()
    #expect(saved.definition == workspace.definition)
    #expect(saved.preferences == workspace.preferences)
    #expect(saved.definitionExternalID == workspace.definitionExternalID)
    #expect(saved.preferencesExternalID == workspace.preferencesExternalID)
    #expect(try Data(contentsOf: info) == oldInfo)
    #expect(
      try FileManager.default.attributesOfItem(atPath: resource.path)[.systemFileNumber]
        as? NSNumber
        == oldResourceAttributes[.systemFileNumber] as? NSNumber)
  }
}
