// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
//
// SPDX-License-Identifier: Apache-2.0

import Foundation
import LDTXWorkspaceAppletModel
import LDTXWorkspaceAppletStore
@testable import LDTXWorkspaceAppletUI
import Testing

@Suite
struct ApplicationSettingsStoreIntegrationTestSuite {
  @Test func applicationSettingsStoreRoundTripsThroughUserDefaults() throws {
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
        == FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(
          "Pictures", isDirectory: true))
    let data = try #require(defaults.data(forKey: ApplicationSettingsStore.applicationOutputPreferencesKey))
    #expect(data.starts(with: Data("bplist".utf8)))
    #expect(try PropertyListDecoder().decode(ApplicationOutputPreferences.self, from: data) == expected)
  }

  @Test func applicationSettingsStoreDoesNotReadAnotherUserDefaultsSuite() {
    let sourceName = "LDTXTests.ApplicationSettingsStore.source.\(UUID().uuidString)"
    let targetName = "LDTXTests.ApplicationSettingsStore.target.\(UUID().uuidString)"
    let source = UserDefaults(suiteName: sourceName)!
    let target = UserDefaults(suiteName: targetName)!
    defer {
      source.removePersistentDomain(forName: sourceName)
      target.removePersistentDomain(forName: targetName)
    }
    ApplicationSettingsStore(userDefaults: source).saveApplicationOutputPreferences(
      ApplicationOutputPreferences(defaultOutputFolderPath: "/tmp/source"))

    #expect(
      ApplicationSettingsStore(userDefaults: target).loadApplicationOutputPreferences()
        == ApplicationOutputPreferences())
  }

  @Test func applicationSettingsStoreIgnoresOldProtobufValues() throws {
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

  @Test func applicationSettingsStoreIgnoresCorruptUserDefaultsValue() {
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
