// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
//
// SPDX-License-Identifier: Apache-2.0

import Foundation
@testable import LDTXApp
import LDTXWorkspace
@testable import LDTXWorkspaceApplet
import Testing

@Suite
struct OutputSettingsModelIntegrationTestSuite {
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

  @MainActor
  @Test func canvasStateDoesNotExposeAnEditableCBRBitRate() {
    let model = OutputCanvasModel()

    #expect(model.state == OutputCanvasModel().state)
  }

  @Test func sdr1080p60AcceptsPositiveCanvasBitRates() {
    #expect(WorkspaceOutputConfiguration.sdr1080p60.isSupportedOutputProfile)
    var configuration = WorkspaceOutputConfiguration.sdr1080p60
    configuration.videoBitRate = 9_000_000
    #expect(configuration.isSupportedOutputProfile)
    configuration.videoBitRate = 0
    #expect(!configuration.isSupportedOutputProfile)
    configuration.videoBitRate = 9_000_000
    configuration.portraitVideoBitRate = 0
    #expect(!configuration.isSupportedOutputProfile)
  }

  @MainActor
  @Test func allDisabledDestinationIsPreservedForStartTimeValidation() {
    let model = OutputDestination(recordsLocally: false, streamsToYouTube: false)

    #expect(model.enabledCaptureOutputMode == nil)
    #expect(model.normalized() == model)
  }

  @Test func unavailableOutputFolderIsPreservedForStartTimeValidation() {
    let model = OutputDestination(
      recordsLocally: true,
      streamsToYouTube: false,
      overridesOutputFolder: true,
      outputFolderPath: "/Volumes/Disconnected/Recordings")

    #expect(model.normalized() == model)
  }

  @Test func enablingOutputFolderOverrideRequiresASelectedFolder() {
    let original = OutputDestination(recordsLocally: true)

    #expect(
      OutputFolderOverrideSelection.applying(
        enabled: true,
        selectedURL: nil,
        to: original
      ) == nil)
  }

  @Test func outputFolderOverrideSelectionAndRemovalAreAtomic() throws {
    let original = OutputDestination(recordsLocally: true)
    let selected = try #require(
      OutputFolderOverrideSelection.applying(
        enabled: true,
        selectedURL: URL(fileURLWithPath: "/tmp/old/../recordings", isDirectory: true),
        to: original
      ))

    #expect(selected.overridesOutputFolder)
    #expect(selected.outputFolderPath == "/tmp/recordings")

    let disabled = try #require(
      OutputFolderOverrideSelection.applying(
        enabled: false,
        selectedURL: nil,
        to: selected
      ))
    #expect(!disabled.overridesOutputFolder)
    #expect(disabled.outputFolderPath == nil)
  }

  @MainActor
  @Test func runtimeServiceSelectionIsDerivedFromDestination() {
    var model = OutputDestination(recordsLocally: true, streamsToYouTube: false)

    #expect(model.enabledCaptureOutputMode == .record)

    model.streamsToYouTube = true
    #expect(model.enabledCaptureOutputMode == .youtubeAndRecord)
  }
}
