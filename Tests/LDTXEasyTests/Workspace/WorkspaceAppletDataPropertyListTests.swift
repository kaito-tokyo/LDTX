// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
//
// SPDX-License-Identifier: Apache-2.0

import Foundation
import LDTXProtos
import LDTXWorkspaceAppletModel
import LDTXWorkspaceAppletUI
import Testing

@MainActor
@Suite
struct WorkspaceAppletDataPropertyListUnitTestSuite {
  @Test func persistsRecordingFolderInAppletData() throws {
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

  @Test func migratesOutputAssignmentsToExternalIDOnce() throws {
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

  @Test func persistsMonitorVolumeWithLocalState() throws {
    let state = WorkspaceLocalState(monitorVolume: -12.5)
    let data = try PropertyListEncoder().encode(state)
    #expect(
      try PropertyListDecoder().decode(WorkspaceLocalState.self, from: data).monitorVolume == -12.5)
    let legacy = try PropertyListEncoder().encode(WorkspaceLocalState())
    #expect(
      try PropertyListDecoder().decode(WorkspaceLocalState.self, from: legacy).monitorVolume == nil)
  }

  @Test func roundTripsTypedAssignmentsInBinaryPropertyList() throws {
    let assignments: [UInt64: WorkspacePhysicalDeviceID] = [
      8: .avCaptureDevice(uniqueID: "camera-uid"), 9: .coreAudioDevice(uid: "microphone-uid"),
    ]
    let encoder = PropertyListEncoder()
    encoder.outputFormat = .binary
    let data = try encoder.encode(assignments)
    #expect(
      try PropertyListDecoder().decode([UInt64: WorkspacePhysicalDeviceID].self, from: data)
        == assignments)
    #expect(data.starts(with: Data("bplist".utf8)))
  }

  @Test func ignoresLegacyAssignmentsWhileRetainingOtherLocalFields() throws {
    let state = WorkspaceLocalState(
      selectedProgramInternalID: 17,
      monitorAudioInputDeviceInternalIDs: [5],
      landscapeYouTubeLiveStreamID: "landscape", portraitYouTubeLiveStreamID: "portrait")
    let encoder = PropertyListEncoder()
    let data = try encoder.encode(state)
    var legacy = try #require(
      PropertyListSerialization.propertyList(from: data, options: 0, format: nil) as? [String: Any]
    )
    legacy["physicalDeviceIDsByInputDeviceInternalID"] = [
      "3": ["avCaptureDevice": ["uniqueID": "legacy-camera"]]
    ]
    let oldData = try PropertyListSerialization.data(
      fromPropertyList: legacy, format: .binary, options: 0)
    #expect(try PropertyListDecoder().decode(WorkspaceLocalState.self, from: oldData) == state)
    let newData = try encoder.encode(
      try PropertyListDecoder().decode(WorkspaceLocalState.self, from: oldData))
    let new = try #require(
      PropertyListSerialization.propertyList(from: newData, options: 0, format: nil)
        as? [String: Any])
    #expect(new["physicalDeviceIDsByInputDeviceInternalID"] == nil)
  }
}
