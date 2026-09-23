// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
//
// SPDX-License-Identifier: Apache-2.0

import Foundation
import LDTXWorkspace
@testable import LDTXWorkspaceApplet
import Testing

@Suite
struct ApplicationSettingsStoreIntegrationTestSuite {
  @Test func applicationSettingsStoreRoundTripsThroughUserDefaults() throws {
    let suiteName = "LDTXTests.ApplicationSettingsStore.roundTrip.\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suiteName))
    defer { defaults.removePersistentDomain(forName: suiteName) }
    let store = ApplicationSettingsStore(userDefaults: defaults)
    let expected = ApplicationOutputPreferences(defaultOutputFolderPath: "/tmp/recordings")

    store.saveApplicationOutputPreferences(expected)

    #expect(store.loadApplicationOutputPreferences() == expected)
    #expect(defaults.data(forKey: ApplicationSettingsStore.applicationOutputPreferencesKey) != nil)
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

  @Test func applicationSettingsStoreMigratesLegacyUserDefaultsValue() throws {
    let suiteName = "LDTXTests.ApplicationSettingsStore.migration.\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suiteName))
    defer { defaults.removePersistentDomain(forName: suiteName) }
    var legacy = Ldtx_App_V1_LegacyOutputSettings()
    legacy.recording.isEnabled = true
    legacy.recording.baseDirectoryPath = "/tmp/legacy-recordings"
    defaults.set(
      try legacy.serializedData(),
      forKey: ApplicationSettingsStore.legacyOutputSettingsKey)

    let preferences = ApplicationSettingsStore(userDefaults: defaults)
      .loadApplicationOutputPreferences()

    #expect(preferences.defaultOutputFolderPath == "/tmp/legacy-recordings")
    #expect(defaults.data(forKey: ApplicationSettingsStore.applicationOutputPreferencesKey) != nil)
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
