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
