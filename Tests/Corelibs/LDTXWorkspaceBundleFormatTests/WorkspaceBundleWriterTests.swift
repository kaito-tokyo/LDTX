// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
// SPDX-License-Identifier: Apache-2.0

import Foundation
import LDTXWorkspaceBundleFormat
import Testing

@Suite
struct WorkspaceBundleWriterIntegrationTestSuite {
  @Test func preservesResourcesAndEnvelopeIdentifiers() throws {
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
    var info = try #require(
      PropertyListSerialization.propertyList(
        from: Data(contentsOf: infoURL), options: [], format: nil)
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
    try WorkspaceBundleWriterV4().write(changed, to: original)
    let reloaded = try WorkspaceBundleReaderV4(at: original).read()
    let copiedInfo = try #require(
      PropertyListSerialization.propertyList(
        from: Data(contentsOf: original.appendingPathComponent("Info.plist")), options: [],
        format: nil)
        as? [String: Any])
    #expect(copiedInfo["CustomMetadata"] as? String == "Preserved")
    #expect(reloaded.definition.displayName == "Edited")
    #expect(reloaded.definitionExternalID == snapshot.definitionExternalID)
    #expect(reloaded.preferencesExternalID == snapshot.preferencesExternalID)
    #expect(
      try Data(contentsOf: original.appendingPathComponent("Resources/image.bin")) == resource)
  }

  @Test func partialSaveLeavesOtherFilesUntouchedAndRetriesAfterFailure() throws {
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
