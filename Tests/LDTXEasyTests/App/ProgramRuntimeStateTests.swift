// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
//
// SPDX-License-Identifier: Apache-2.0

import LDTXProgram
import LDTXWorkspaceAppletModel
import LDTXWorkspaceAppletService
import LDTXWorkspaceAppletStore
import LDTXWorkspaceAppletUI
import Testing

@Suite
struct ProgramRuntimeStateUnitTestSuite {
  @Test
  func videoPTSUsesHostClockWhenNoWorkspaceMasterIsSelected() {
    #expect(
      workspaceVideoPTSMasterCameraID(
        masterInputDeviceID: nil,
        workspaceInputDevices: []
      ) == nil)
  }

  @Test
  func videoPTSUsesSelectedWorkspaceVideoInput() {
    let inputDevices = [
      ProgramInputDeviceRecord(
        name: "Selected Camera",
        kind: .video,
        physicalDeviceID: "selected-camera"
      )
    ]

    #expect(
      workspaceVideoPTSMasterCameraID(
        masterInputDeviceID: "Selected Camera",
        workspaceInputDevices: inputDevices
      ) == "selected-camera")
  }

  @Test
  func videoPTSDoesNotUseAudioInputAsMaster() {
    let inputDevices = [
      ProgramInputDeviceRecord(
        name: "Microphone",
        kind: .audio,
        physicalDeviceID: "microphone"
      )
    ]

    #expect(
      workspaceVideoPTSMasterCameraID(
        masterInputDeviceID: "Microphone",
        workspaceInputDevices: inputDevices
      ) == nil)
  }
}
