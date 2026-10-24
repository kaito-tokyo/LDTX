// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
//
// SPDX-License-Identifier: Apache-2.0

import LDTXProgram
import LDTXWorkspaceAppletModel
import LDTXWorkspaceAppletService
import LDTXWorkspaceAppletStore
import LDTXWorkspaceAppletUI
import Testing

@Suite(.tags(.easy))
struct ProgramRuntimeStateUnitTestSuite {
  @Test("LUB-1059: Video PTS uses host clock when no workspace master is selected")
  func videoPTSUsesHostClockWhenNoWorkspaceMasterIsSelected() {
    #expect(
      workspaceVideoPTSMasterCameraID(
        masterInputDeviceID: nil,
        workspaceInputDevices: []
      ) == nil)
  }

  @Test("LUB-1059: Video PTS uses selected workspace video input")
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

  @Test("LUB-1059: Video PTS does not use audio input as master")
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
