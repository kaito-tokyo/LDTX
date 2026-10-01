// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
// SPDX-License-Identifier: Apache-2.0

import Foundation
import LDTXProtos
import LDTXWorkspaceAppletModel
import LDTXWorkspaceAppletUI
import LDTXWorkspaceBundleFormat
import Testing

@Suite
struct WorkspaceDocumentPackageIntegrationTestSuite {
  @Test func preservesResourcesAndEnvelopeIdentifiers() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let original = root.appendingPathComponent("Original.ldtxworkspace")
    let savedAs = root.appendingPathComponent("Copy.ldtxworkspace")
    let snapshot = WorkspaceV4Bundle(
      definitionExternalID: UUID().uuidString.lowercased(),
      preferencesExternalID: UUID().uuidString.lowercased(),
      definition: .init(), preferences: .init())
    try WorkspaceDocumentPackage.fileWrapper(for: snapshot, preserving: nil)
      .write(to: original, options: .atomic, originalContentsURL: nil)
    let infoURL = original.appendingPathComponent("Info.plist")
    var info = try #require(
      PropertyListSerialization.propertyList(
        from: Data(contentsOf: infoURL), options: 0, format: nil)
        as? [String: Any])
    info["CustomMetadata"] = "Preserved"
    try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0).write(
      to: infoURL)
    let resourceURL = original.appendingPathComponent("Resources/image.bin")
    try FileManager.default.createDirectory(
      at: resourceURL.deletingLastPathComponent(), withIntermediateDirectories: true)
    let resource = Data([0, 1, 2, 255])
    try resource.write(to: resourceURL)
    var changed = snapshot
    changed.definition.displayName = "Edited"
    try WorkspaceDocumentPackage.fileWrapper(for: changed, preserving: original)
      .write(to: savedAs, options: .atomic, originalContentsURL: nil)
    let reloaded = try WorkspaceBundleReaderV4(at: savedAs).read()
    let copiedInfo = try #require(
      PropertyListSerialization.propertyList(
        from: Data(contentsOf: savedAs.appendingPathComponent("Info.plist")), options: 0,
        format: nil)
        as? [String: Any])
    #expect(copiedInfo["CustomMetadata"] as? String == "Preserved")
    #expect(reloaded.definition.displayName == "Edited")
    #expect(reloaded.definitionExternalID == snapshot.definitionExternalID)
    #expect(reloaded.preferencesExternalID == snapshot.preferencesExternalID)
    #expect(try Data(contentsOf: savedAs.appendingPathComponent("Resources/image.bin")) == resource)
    #expect(try WorkspaceBundleReaderV4(at: original).read().definition.displayName == "")
  }

  @Test @MainActor func transientLocalStateIsOnlyPersistedAfterSave() throws {
    let suite = UUID().uuidString
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let data = WorkspaceAppletData(userDefaults: defaults)
    let transient = URL(string: "ldtx-untitled://workspace/test")!
    let saved = URL(fileURLWithPath: "/tmp/Saved.ldtxworkspace")
    data.registerTransientState(at: transient)
    data.setState(.init(selectedProgramInternalID: 42), for: transient)
    #expect(data.state(for: transient).selectedProgramInternalID == 42)
    #expect(
      WorkspaceAppletData(userDefaults: defaults).state(for: transient).selectedProgramInternalID
        == nil)
    data.copyState(from: transient, to: saved)
    #expect(
      WorkspaceAppletData(userDefaults: defaults).state(for: saved).selectedProgramInternalID == 42)
  }
}
