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
    try WorkspaceDocumentPackage.write(snapshot, to: original, createsPackage: true)
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
    try WorkspaceDocumentPackage.write(
      changed, to: savedAs, preserving: original, createsPackage: true)
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

  @Test func partialSaveLeavesOtherFilesUntouchedAndRetriesAfterFailure() throws {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: url) }
    var workspace = WorkspaceV4Bundle(
      definitionExternalID: UUID().uuidString.lowercased(),
      preferencesExternalID: UUID().uuidString.lowercased(),
      definition: .init(), preferences: .init())
    try WorkspaceDocumentPackage.write(workspace, to: url, createsPackage: true)
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
    workspace.preferences.monitorVolume = -6
    #expect(throws: (any Error).self) { try WorkspaceDocumentPackage.write(workspace, to: url) }
    #expect(try Data(contentsOf: info) == oldInfo)
    #expect(try Data(contentsOf: resource) == Data("Resource".utf8))
    #expect(
      try FileManager.default.attributesOfItem(atPath: resource.path)[.systemFileNumber]
        as? NSNumber
        == oldResourceAttributes[.systemFileNumber] as? NSNumber)
    try FileManager.default.removeItem(at: preferences)
    try oldPreferences.write(to: preferences)
    try WorkspaceDocumentPackage.write(workspace, to: url)
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
