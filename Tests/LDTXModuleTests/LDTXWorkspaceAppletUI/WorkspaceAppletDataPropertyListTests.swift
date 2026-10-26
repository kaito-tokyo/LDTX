// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
//
// SPDX-License-Identifier: Apache-2.0

import Foundation
import LDTXCorelibs
import LDTXWorkspaceAppletModel
import LDTXWorkspaceAppletUI
import Testing

@MainActor
@Suite(.tags(.easy))
struct WorkspaceAppletDataPropertyListUnitTestSuite {
  private struct LegacyLocalState: Codable {
    var state: WorkspaceLocalState
    var physicalDeviceIDsByInputDeviceInternalID: [String: [String: [String: String]]]?

    enum CodingKeys: String, CodingKey {
      case physicalDeviceIDsByInputDeviceInternalID
    }

    init(state: WorkspaceLocalState) {
      self.state = state
    }

    init(from decoder: any Decoder) throws {
      state = try WorkspaceLocalState(from: decoder)
      let container = try decoder.container(keyedBy: CodingKeys.self)
      physicalDeviceIDsByInputDeviceInternalID = try container.decodeIfPresent(
        [String: [String: [String: String]]].self,
        forKey: .physicalDeviceIDsByInputDeviceInternalID)
    }

    func encode(to encoder: any Encoder) throws {
      try state.encode(to: encoder)
      var container = encoder.container(keyedBy: CodingKeys.self)
      try container.encodeIfPresent(
        physicalDeviceIDsByInputDeviceInternalID,
        forKey: .physicalDeviceIDsByInputDeviceInternalID)
    }
  }

  @Test("LUB-1057: Transient local state is only persisted after save")
  func transientLocalStateIsOnlyPersistedAfterSave() throws {
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

  @Test("LUB-1057: Runtime state uses external assignments without changing path state")
  func runtimeStateUsesExternalAssignmentsWithoutChangingPathState() throws {
    let suite = "RuntimeLocalState.\(UUID())"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let data = WorkspaceAppletData(userDefaults: defaults)
    let url = URL(fileURLWithPath: "/tmp/RuntimeLocalState.ldtxworkspace")
    let externalID = UUID()
    var original = WorkspaceLocalState()
    original.monitorVolume = -12
    original.selectedProgramInternalID = 123
    original.recordingFolderPath = "/tmp/legacy-recordings"
    data.setState(original, for: url)
    data.recordingFolderPaths[externalID] = "/tmp/current-recordings"
    data.landscapeYouTubeLiveStreamIDs[externalID] = "landscape"
    let runtime = data.state(for: url, externalID: externalID)
    #expect(runtime.monitorVolume == -12)
    #expect(runtime.selectedProgramInternalID == 123)
    #expect(runtime.recordingFolderPath == "/tmp/current-recordings")
    #expect(runtime.landscapeYouTubeLiveStreamID == "landscape")
    #expect(data.state(for: url) == original)
    #expect(data.state(for: url, externalID: nil) == original)
  }

  @Test("LUB-1057: Persists recording folder in applet data")
  func persistsRecordingFolderInAppletData() throws {
    let suiteName = "RecordingFolderTest.\(UUID())"
    let defaults = try #require(UserDefaults(suiteName: suiteName))
    defer { defaults.removePersistentDomain(forName: suiteName) }
    let externalID = UUID()
    let otherID = UUID()
    let appletData = WorkspaceAppletData(userDefaults: defaults)
    appletData.recordingFolderPaths[externalID] = "/tmp/recordings"
    appletData.recordingFolderPaths[otherID] = "/tmp/other-recordings"
    appletData.landscapeYouTubeLiveStreamIDs[externalID] = "landscape"
    appletData.portraitYouTubeLiveStreamIDs[externalID] = "portrait"
    let restored = WorkspaceAppletData(userDefaults: defaults)
    #expect(restored.recordingFolderPaths[externalID] == "/tmp/recordings")
    #expect(restored.landscapeYouTubeLiveStreamIDs[externalID] == "landscape")
    #expect(restored.portraitYouTubeLiveStreamIDs[externalID] == "portrait")
    restored.recordingFolderPaths[externalID] = nil
    let reopened = WorkspaceAppletData(userDefaults: defaults)
    #expect(reopened.recordingFolderPaths[externalID] == nil)
    #expect(reopened.recordingFolderPaths[otherID] == "/tmp/other-recordings")
  }

  @Test("LUB-1057: Migrates output assignments to external ID once")
  func migratesOutputAssignmentsToExternalIDOnce() throws {
    let suiteName = "OutputMigrationTest.\(UUID())"
    let defaults = try #require(UserDefaults(suiteName: suiteName))
    defer { defaults.removePersistentDomain(forName: suiteName) }
    let appletData = WorkspaceAppletData(userDefaults: defaults)
    let url = URL(fileURLWithPath: "/tmp/LegacyWorkspace.ldtxworkspace")
    let externalID = UUID()
    appletData.setState(
      .init(
        recordingFolderPath: "/tmp/legacy",
        monitorVolume: -12, landscapeYouTubeLiveStreamID: "legacy-stream"), for: url)
    appletData.migrateOutputData(from: url, externalID: externalID)
    #expect(appletData.recordingFolderPaths[externalID] == "/tmp/legacy")
    #expect(appletData.landscapeYouTubeLiveStreamIDs[externalID] == "legacy-stream")
    #expect(appletData.state(for: url).monitorVolume == -12)
    appletData.recordingFolderPaths[externalID] = nil
    appletData.migrateOutputData(from: url, externalID: externalID)
    #expect(appletData.recordingFolderPaths[externalID] == nil)
  }

  @Test("LUB-1057: Persists monitor volume with local state")
  func persistsMonitorVolumeWithLocalState() throws {
    let state = WorkspaceLocalState(monitorVolume: -12.5)
    let data = try PropertyListEncoder().encode(state)
    #expect(
      try PropertyListDecoder().decode(WorkspaceLocalState.self, from: data).monitorVolume == -12.5)
    let legacy = try PropertyListEncoder().encode(WorkspaceLocalState())
    #expect(
      try PropertyListDecoder().decode(WorkspaceLocalState.self, from: legacy).monitorVolume == nil)
  }

  @Test("LUB-1057: Ignores legacy assignments while retaining other local fields")
  func ignoresLegacyAssignmentsWhileRetainingOtherLocalFields() throws {
    let state = WorkspaceLocalState(
      selectedProgramInternalID: 17,
      monitorAudioInputDeviceInternalIDs: [5],
      landscapeYouTubeLiveStreamID: "landscape", portraitYouTubeLiveStreamID: "portrait")
    let encoder = PropertyListEncoder()
    encoder.outputFormat = .binary
    var legacy = LegacyLocalState(state: state)
    legacy.physicalDeviceIDsByInputDeviceInternalID = [
      "3": ["avCaptureDevice": ["uniqueID": "legacy-camera"]]
    ]
    let oldData = try encoder.encode(legacy)
    #expect(try PropertyListDecoder().decode(WorkspaceLocalState.self, from: oldData) == state)
    let newData = try encoder.encode(
      try PropertyListDecoder().decode(WorkspaceLocalState.self, from: oldData))
    let new = try PropertyListDecoder().decode(LegacyLocalState.self, from: newData)
    #expect(new.physicalDeviceIDsByInputDeviceInternalID == nil)
  }
}
