// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
//
// SPDX-License-Identifier: Apache-2.0

import LDTXAppUI
import LDTXProgram
import LDTXWorkspace
import Testing

struct ProgramRuntimeStateTests {
  @Test
  func videoPTSUsesHostClockWhenNoWorkspaceMasterIsSelected() {
    #expect(workspaceVideoPTSMasterCameraID(
      masterInputDeviceID: nil,
      workspaceInputDevices: []
    ) == nil)
  }

  @Test
  func videoPTSUsesSelectedWorkspaceVideoInput() {
    let inputDevices = [WorkspaceInputDeviceRecord(
      name: "Selected Camera",
      kind: .video,
      physicalDeviceID: "selected-camera"
    )]

    #expect(workspaceVideoPTSMasterCameraID(
      masterInputDeviceID: "Selected Camera",
      workspaceInputDevices: inputDevices
    ) == "selected-camera")
  }

  @Test
  func videoPTSDoesNotUseAudioInputAsMaster() {
    let inputDevices = [WorkspaceInputDeviceRecord(
      name: "Microphone",
      kind: .audio,
      physicalDeviceID: "microphone"
    )]

    #expect(workspaceVideoPTSMasterCameraID(
      masterInputDeviceID: "Microphone",
      workspaceInputDevices: inputDevices
    ) == nil)
  }
}
