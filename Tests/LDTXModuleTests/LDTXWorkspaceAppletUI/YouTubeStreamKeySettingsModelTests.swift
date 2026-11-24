// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
// SPDX-License-Identifier: Apache-2.0

import Foundation
import LDTXCorelibs
@testable import LDTXWorkspaceAppletUI
import Security
import Testing

@MainActor
@Suite("YouTube stream key settings", .tags(.easy))
struct YouTubeStreamKeySettingsModelIntegrationTestSuite {
  private static let url = "rtmps://a.rtmps.youtube.com/live2"

  @Test("Adds and edits configurations seen by the shared AppletData")
  func addsAndEditsConfigurations() throws {
    try withAppletData { appletData, keychain, appletDataDefaults in
      let model = YouTubeStreamKeySettingsModel(appletData: appletData)
      let added = try model.save(
        .init(id: "main", name: " Main ", streamURL: Self.url, streamKey: " key-1\n"))
      #expect(added.name == "Main")
      #expect(added.streamKey == "key-1")
      #expect(appletData.youtubeStreamKeyConfigurations == [added])

      var edited = added
      edited.name = "Renamed"
      try model.save(edited)
      #expect(appletData.youtubeStreamKeyConfigurations.map(\.name) == ["Renamed"])

      let reloaded = WorkspaceAppletData(
        userDefaults: appletDataDefaults, streamKeyKeychainOperations: keychain.operations)
      #expect(try reloaded.loadYouTubeStreamKeyConfigurations().map(\.name) == ["Renamed"])
    }
  }

  @Test("Editing connection fields forgets the imported YouTube stream")
  func editingConnectionFieldsClearsSourceLiveStream() throws {
    try withAppletData { appletData, _, _ in
      let model = YouTubeStreamKeySettingsModel(appletData: appletData)
      var configuration = try model.save(
        .init(
          id: "main", sourceLiveStreamID: "stream", name: "Main", streamURL: Self.url,
          streamKey: "key-1"))
      #expect(configuration.sourceLiveStreamID == "stream")
      configuration.name = "Renamed"
      configuration = try model.save(configuration)
      #expect(configuration.sourceLiveStreamID == "stream")
      configuration.streamKey = "key-2"
      configuration = try model.save(configuration)
      #expect(configuration.sourceLiveStreamID == nil)
    }
  }

  @Test("Deleting a configuration keeps Workspace assignments")
  func deletingKeepsAssignments() throws {
    try withAppletData { appletData, _, _ in
      let model = YouTubeStreamKeySettingsModel(appletData: appletData)
      try model.save(.init(id: "main", name: "Main", streamURL: Self.url, streamKey: "key-1"))
      let workspace = UUID()
      appletData.landscapeYouTubeLiveStreamIDs[workspace] = "main"
      try model.delete(id: "main")
      #expect(appletData.youtubeStreamKeyConfigurations.isEmpty)
      #expect(appletData.landscapeYouTubeLiveStreamIDs[workspace] == "main")
    }
  }

  @Test("A Keychain read failure blocks saving and is reported")
  func readFailureBlocksSaving() throws {
    try withAppletData { appletData, keychain, _ in
      let model = YouTubeStreamKeySettingsModel(appletData: appletData)
      try model.save(.init(id: "main", name: "Main", streamURL: Self.url, streamKey: "key-1"))
      let stored = keychain.items
      keychain.fail("copyMatching", with: errSecInteractionNotAllowed)

      #expect(throws: YouTubeStreamKeyConfigurationError.loadFailed) {
        try model.save(.init(id: "other", name: "Other", streamURL: Self.url, streamKey: "key-2"))
      }
      #expect(throws: YouTubeStreamKeyConfigurationError.loadFailed) {
        try model.delete(id: "main")
      }
      #expect(keychain.items == stored)
      #expect(
        model.loadErrorMessage
          == YouTubeStreamKeyConfigurationError.loadFailed.localizedDescription)
    }
  }

  @Test("Importing a new LiveStream picks an unused name")
  func importingNewLiveStreamPicksUnusedName() throws {
    try withAppletData { appletData, _, _ in
      let model = YouTubeStreamKeySettingsModel(appletData: appletData)
      try model.save(.init(id: "manual", name: "Main", streamURL: Self.url, streamKey: "key-1"))
      let imported = try model.importConfiguration(
        .init(
          id: "ignored", sourceLiveStreamID: "stream", name: "Main", streamURL: Self.url,
          streamKey: "key-2"))
      #expect(imported.name == "Main (2)")
      #expect(imported.id != "ignored")
      #expect(imported.sourceLiveStreamID == "stream")
      #expect(appletData.youtubeStreamKeyConfigurations.count == 2)
    }
  }

  @Test("Importing a LiveStream again refreshes its configuration in place")
  func reimportRefreshesInPlace() throws {
    try withAppletData { appletData, _, _ in
      let model = YouTubeStreamKeySettingsModel(appletData: appletData)
      let first = try model.importConfiguration(
        .init(sourceLiveStreamID: "stream", name: "Main", streamURL: Self.url, streamKey: "old"))
      var renamed = first
      renamed.name = "Renamed"
      try model.save(renamed)
      let refreshed = try model.importConfiguration(
        .init(sourceLiveStreamID: "stream", name: "Main", streamURL: Self.url, streamKey: "new"))
      #expect(refreshed.id == first.id)
      #expect(refreshed.name == "Renamed")
      #expect(refreshed.streamKey == "new")
      #expect(refreshed.sourceLiveStreamID == "stream")
      #expect(appletData.youtubeStreamKeyConfigurations == [refreshed])
    }
  }

  @Test("Validation explains which field prevents saving")
  func validationMessages() {
    let existing = YouTubeRTMPSStreamKeyConfiguration(
      id: "main", name: "Main", streamURL: Self.url, streamKey: "key-1")
    func message(_ draft: YouTubeRTMPSStreamKeyConfiguration) -> String? {
      YouTubeStreamKeySettingsModel.validationMessage(for: draft, among: [existing])
    }
    #expect(message(.init(name: " ", streamURL: Self.url, streamKey: "k")) == "Enter a name.")
    #expect(message(.init(name: "A", streamURL: "", streamKey: "k")) == "Enter a stream URL.")
    #expect(message(.init(name: "A", streamURL: Self.url, streamKey: " ")) == "Enter a stream key.")
    #expect(
      message(.init(name: "A", streamURL: "rtmp://a.rtmp.youtube.com/live2", streamKey: "k"))?
        .hasPrefix("The stream URL") == true)
    #expect(
      message(
        .init(name: "A", streamURL: Self.url, backupServerURL: "https://x/live2", streamKey: "k"))?
        .hasPrefix("The backup server URL") == true)
    #expect(
      message(.init(name: "Main ", streamURL: Self.url, streamKey: "k"))
        == "Another stream key already uses this name.")
    #expect(
      message(.init(name: "A", streamURL: Self.url, streamKey: "key-1\n"))
        == "Another configuration already uses this stream key.")
    #expect(message(existing) == nil)
    #expect(message(.init(name: "A", streamURL: Self.url, streamKey: "key-2")) == nil)
  }

  @Test("Saving an invalid draft writes nothing")
  func invalidDraftWritesNothing() throws {
    try withAppletData { appletData, keychain, _ in
      let model = YouTubeStreamKeySettingsModel(appletData: appletData)
      #expect(throws: YouTubeStreamKeySettingsError(message: "Enter a stream key.")) {
        try model.save(.init(name: "Main", streamURL: Self.url))
      }
      #expect(keychain.items.isEmpty)
    }
  }

  private func withAppletData(
    _ body: (WorkspaceAppletData, FakeDataProtectionKeychain, UserDefaults) throws -> Void
  ) throws {
    let suiteName = "YouTubeStreamKeySettingsModelTests.\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suiteName))
    defer { defaults.removePersistentDomain(forName: suiteName) }
    let keychain = FakeDataProtectionKeychain()
    try body(
      WorkspaceAppletData(userDefaults: defaults, streamKeyKeychainOperations: keychain.operations),
      keychain, defaults)
  }
}
