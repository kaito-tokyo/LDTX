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
  @Test func roundTripsTypedDeviceIdentifiersInBinaryPropertyList() throws {
    let state = WorkspaceLocalState(
      physicalDeviceIDsByInputDeviceInternalID: [
        8: .avCaptureDevice(uniqueID: "camera-uid"),
        9: .coreAudioDevice(uid: "microphone-uid"),
      ])
    let encoder = PropertyListEncoder()
    encoder.outputFormat = .binary
    let data = try encoder.encode(state)
    let decoded = try PropertyListDecoder().decode(WorkspaceLocalState.self, from: data)

    #expect(decoded == state)
    #expect(data.starts(with: Data("bplist".utf8)))
  }

  @Test func discardsOldProtobufStoreAndPersistsNewLocalState() throws {
    let suiteName = "WorkspaceAppletDataPropertyListTests.\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suiteName))
    defer { defaults.removePersistentDomain(forName: suiteName) }
    let oldKey = "tokyo.kaito.ldtx.workspace-local-state.v1"
    let newKey = "tokyo.kaito.ldtx.workspace-local-state.v2"
    var oldStore = Ldtx_App_V1_WorkspaceLocalStateStore()
    var oldState = Ldtx_App_V1_WorkspaceLocalState()
    oldState.selectedProgramInternalID = 42
    oldStore.statesByWorkspacePath["/tmp/Workspace.ldtxworkspace"] = oldState
    defaults.set(try oldStore.serializedData(), forKey: oldKey)

    let url = URL(fileURLWithPath: "/tmp/Workspace.ldtxworkspace")
    let appletData = WorkspaceAppletData(userDefaults: defaults)
    #expect(appletData.state(for: url) == WorkspaceLocalState())

    let state = WorkspaceLocalState(
      selectedProgramInternalID: 17,
      physicalDeviceIDsByInputDeviceInternalID: [
        3: .avCaptureDevice(uniqueID: "camera"),
        5: .coreAudioDevice(uid: "microphone"),
      ],
      monitorAudioInputDeviceInternalIDs: [5],
      synchronizesLandscapeMixToPortraitByProgramInternalID: [17: true],
      landscapeYouTubeLiveStreamID: "landscape",
      portraitYouTubeLiveStreamID: "portrait")
    appletData.setState(state, for: url)

    #expect(defaults.data(forKey: oldKey) == nil)
    #expect(defaults.data(forKey: newKey)?.starts(with: Data("bplist".utf8)) == true)
    #expect(WorkspaceAppletData(userDefaults: defaults).state(for: url) == state)
  }

  @Test func typedIdentifiersAreNotInterchangeable() {
    let state = WorkspaceLocalState(
      physicalDeviceIDsByInputDeviceInternalID: [
        3: .coreAudioDevice(uid: "microphone"),
        5: .avCaptureDevice(uniqueID: "camera"),
      ])

    #expect(cameraID(for: 3, in: state) == nil)
    #expect(cameraID(for: 5, in: state) == "camera")
    #expect(audioID(for: 3, in: state) == "microphone")
    #expect(audioID(for: 5, in: state) == nil)
  }

  private func cameraID(for inputID: UInt64, in state: WorkspaceLocalState) -> String? {
    guard case .avCaptureDevice(let id)? = state.physicalDeviceIDsByInputDeviceInternalID[inputID]
    else { return nil }
    return id
  }

  private func audioID(for inputID: UInt64, in state: WorkspaceLocalState) -> String? {
    guard case .coreAudioDevice(let id)? = state.physicalDeviceIDsByInputDeviceInternalID[inputID]
    else { return nil }
    return id
  }
}
