// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
//
// SPDX-License-Identifier: Apache-2.0

import Foundation
import LDTXWorkspaceAppletModel
import LDTXWorkspaceAppletStore
@testable import LDTXWorkspaceAppletUI
import Testing

extension OutputTestSuite {
  @Suite
  struct ApplicationSettingsStoreIntegrationTestSuite {
    @Test("LUB-1028: Application settings store round trips through user defaults")
    func applicationSettingsStoreRoundTripsThroughUserDefaults() throws {
      let suiteName = "LDTXTests.ApplicationSettingsStore.roundTrip.\(UUID().uuidString)"
      let defaults = try #require(UserDefaults(suiteName: suiteName))
      defer { defaults.removePersistentDomain(forName: suiteName) }
      let store = ApplicationSettingsStore(userDefaults: defaults)
      let expected = ApplicationOutputPreferences(
        defaultOutputFolderPath: "/tmp/recordings", screenshotsFolderPath: "/tmp/pictures")

      store.saveApplicationOutputPreferences(expected)

      #expect(store.loadApplicationOutputPreferences() == expected)
      #expect(expected.screenshotsDirectory.path == "/tmp/pictures")
      #expect(
        ApplicationOutputPreferences().screenshotsDirectory
          == URL.moviesDirectory.resolvingSymlinksInPath())
      #expect(ApplicationOutputPreferences().defaultOutputDirectory == nil)
      let data = try #require(
        defaults.data(forKey: ApplicationSettingsStore.applicationOutputPreferencesKey))
      #expect(data.starts(with: Data("bplist".utf8)))
      #expect(
        try PropertyListDecoder().decode(ApplicationOutputPreferences.self, from: data) == expected)
    }

    @Test("Selected output folders persist a security-scoped bookmark with their path")
    func selectedOutputFoldersPersistBookmarks() throws {
      let suiteName = "LDTXTests.ApplicationSettingsStore.bookmarks.\(UUID().uuidString)"
      let defaults = try #require(UserDefaults(suiteName: suiteName))
      defer { defaults.removePersistentDomain(forName: suiteName) }
      let root = FileManager.default.temporaryDirectory.appendingPathComponent(
        "LDTXTests-\(UUID().uuidString)", isDirectory: true)
      let recordings = root.appendingPathComponent("Recordings", isDirectory: true)
      let pictures = root.appendingPathComponent("Pictures", isDirectory: true)
      try FileManager.default.createDirectory(at: recordings, withIntermediateDirectories: true)
      try FileManager.default.createDirectory(at: pictures, withIntermediateDirectories: true)
      defer { try? FileManager.default.removeItem(at: root) }
      let store = ApplicationSettingsStore(userDefaults: defaults)
      var preferences = ApplicationOutputPreferences()

      preferences.setDefaultOutputFolder(recordings)
      preferences.setScreenshotsFolder(pictures)
      store.saveApplicationOutputPreferences(preferences)
      let restored = store.loadApplicationOutputPreferences()

      #expect(restored == preferences)
      #expect(restored.defaultOutputFolderPath == recordings.standardizedFileURL.path)
      #expect(restored.defaultOutputFolderBookmark != nil)
      #expect(restored.screenshotsFolderBookmark != nil)
      #expect(
        restored.defaultOutputDirectory?.resolvingSymlinksInPath().path
          == recordings.resolvingSymlinksInPath().path)
      #expect(
        restored.screenshotsDirectory.resolvingSymlinksInPath().path
          == pictures.resolvingSymlinksInPath().path)

      preferences.setDefaultOutputFolder(nil)
      preferences.setScreenshotsFolder(nil)
      #expect(preferences == ApplicationOutputPreferences())
    }

    @Test("Output folders without a bookmark fall back to their stored path")
    func outputFoldersWithoutBookmarkUseStoredPath() {
      let preferences = ApplicationOutputPreferences(
        defaultOutputFolderPath: "/tmp/recordings", screenshotsFolderPath: "/tmp/pictures",
        defaultOutputFolderBookmark: Data([0x00]), screenshotsFolderBookmark: nil)

      #expect(preferences.defaultOutputDirectory?.path == "/tmp/recordings")
      #expect(preferences.screenshotsDirectory.path == "/tmp/pictures")
    }

    @Test("LUB-1028: Application settings store ignores old Protobuf values")
    func applicationSettingsStoreIgnoresOldProtobufValues() throws {
      let suiteName = "LDTXTests.ApplicationSettingsStore.oldFormat.\(UUID().uuidString)"
      let defaults = try #require(UserDefaults(suiteName: suiteName))
      defer { defaults.removePersistentDomain(forName: suiteName) }
      let path = Array("/tmp/old-recordings".utf8)
      defaults.set(
        Data([UInt8(0x0a), UInt8(path.count)] + path),
        forKey: "tokyo.kaito.ldtx.application-output-preferences.v1")
      let store = ApplicationSettingsStore(userDefaults: defaults)
      #expect(store.loadApplicationOutputPreferences() == ApplicationOutputPreferences())
      let expected = ApplicationOutputPreferences(defaultOutputFolderPath: "/tmp/new-recordings")
      store.saveApplicationOutputPreferences(expected)
      #expect(store.loadApplicationOutputPreferences() == expected)
    }

    @Test("LUB-1028: Application settings store ignores corrupt user defaults value")
    func applicationSettingsStoreIgnoresCorruptUserDefaultsValue() {
      let suiteName = "LDTXTests.ApplicationSettingsStore.corrupt.\(UUID().uuidString)"
      let defaults = UserDefaults(suiteName: suiteName)!
      defer { defaults.removePersistentDomain(forName: suiteName) }
      defaults.set(
        Data([0xFF, 0x00]), forKey: ApplicationSettingsStore.applicationOutputPreferencesKey)

      #expect(
        ApplicationSettingsStore(userDefaults: defaults).loadApplicationOutputPreferences()
          == ApplicationOutputPreferences())
    }

  }
}
