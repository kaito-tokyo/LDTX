// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
//
// SPDX-License-Identifier: Apache-2.0

import LDTXAppUI
import LDTXProgram
import Testing

struct ProgramRuntimeStateTests {
  @Test
  func videoPTSFallsBackToFirstMappedCamera() {
    let unavailableStep = CompositeProgramStep(
      component: .inputCameraDevice(InputDeviceComponent()))
    let availableStep = CompositeProgramStep(component: .inputCameraDevice(InputDeviceComponent()))
    let composite = CompositeProgramDefinition(steps: [unavailableStep, availableStep])
    let availableKey = composite.inputCameraDeviceMappingKey(for: availableStep)

    #expect(
      programVideoPTSInputKey(
        for: .composite,
        composite: composite,
        cameraIDsByInputKey: [availableKey: "camera-id"]
      ) == availableKey)
  }

  @Test
  func videoPTSUsesSelectedMappedCamera() {
    let firstStep = CompositeProgramStep(component: .inputCameraDevice(InputDeviceComponent()))
    let selectedStep = CompositeProgramStep(component: .inputCameraDevice(InputDeviceComponent()))
    var composite = CompositeProgramDefinition(steps: [firstStep, selectedStep])
    let firstKey = composite.inputCameraDeviceMappingKey(for: firstStep)
    let selectedKey = composite.inputCameraDeviceMappingKey(for: selectedStep)
    composite.programVideoPTSInputKey = selectedKey

    #expect(
      programVideoPTSInputKey(
        for: .composite,
        composite: composite,
        cameraIDsByInputKey: [firstKey: "first-camera", selectedKey: "selected-camera"]
      ) == selectedKey)
  }

  @Test
  func videoPTSUsesHostClockWithoutMappedCamera() {
    let step = CompositeProgramStep(component: .inputCameraDevice(InputDeviceComponent()))
    let composite = CompositeProgramDefinition(steps: [step])

    #expect(
      programVideoPTSInputKey(
        for: .composite,
        composite: composite,
        cameraIDsByInputKey: [:]
      ) == nil)
  }
}
