// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
// SPDX-License-Identifier: Apache-2.0

import LDTXProtos
@testable import LDTXWorkspaceAppletUI
import Testing

@Suite
@MainActor
struct WorkspaceResourceAdditionUnitTestSuite {
  @Test func deviceNameFallsBackAndExplicitNameIsTrimmed() throws {
    let state = WorkspaceUIState(definition: .init(), preferences: .init())
    let camera = WorkspaceAddDeviceOption(id: .avCaptureDevice(uniqueID: "camera"), name: "Camera")
    var draft = WorkspaceAddDraft()
    draft.physicalDeviceID = camera.id
    let id = try WorkspaceResourceAddition.add(
      sheet: .device, draft: draft, devices: [camera], uiState: state)
    #expect(state.definition.inputDevices.first?.videoDevice.displayName == "Camera")
    #expect(state.inspectorSelector == .init(kind: .videoInputDevice, internalID: id))
    let audio = WorkspaceAddDeviceOption(id: .coreAudioDevice(uid: "camera"), name: "Microphone")
    draft.physicalDeviceID = audio.id
    draft.name = "  Voice  "
    try WorkspaceResourceAddition.add(
      sheet: .device, draft: draft, devices: [audio], uiState: state)
    #expect(state.definition.inputDevices.last?.audioDevice.displayName == "Voice")
    #expect(state.inspectorSelector?.kind == .audioInputDevice)
  }

  @Test func rejectedAddsLeaveDefinitionAndSelectionUnchanged() throws {
    let state = WorkspaceUIState(definition: .init(), preferences: .init())
    var draft = WorkspaceAddDraft()
    draft.componentKind = .solidColor
    draft.name = "  "
    let definition = state.definition
    let selection = state.inspectorSelector
    #expect(throws: (any Error).self) {
      try WorkspaceResourceAddition.add(
        sheet: .videoComponent, draft: draft, devices: [], uiState: state)
    }
    draft.name = "Solid Color"
    state.isOutputActive = true
    #expect(throws: (any Error).self) {
      try WorkspaceResourceAddition.add(
        sheet: .videoComponent, draft: draft, devices: [], uiState: state)
    }
    state.isOutputActive = false
    draft.componentKind = .vfxSource
    draft.videoInputID = 99
    #expect(throws: (any Error).self) {
      try WorkspaceResourceAddition.add(
        sheet: .videoComponent, draft: draft, devices: [], uiState: state)
    }
    #expect(throws: (any Error).self) {
      try WorkspaceResourceAddition.add(sheet: .vision, draft: draft, devices: [], uiState: state)
    }
    draft.physicalDeviceID = .avCaptureDevice(uniqueID: "disconnected")
    #expect(throws: (any Error).self) {
      try WorkspaceResourceAddition.add(sheet: .device, draft: draft, devices: [], uiState: state)
    }
    #expect(state.definition == definition)
    #expect(state.inspectorSelector == selection)
  }

  @Test func duplicateNamesAreRejectedAcrossResourceKinds() throws {
    let state = WorkspaceUIState(definition: .init(), preferences: .init())
    state.definition.inputDevices = [WorkspaceResourceFactory.makeVideoInput(id: 1, name: "Shared")]
    var draft = WorkspaceAddDraft()
    draft.name = " Shared "
    draft.componentKind = .clock
    draft.videoInputID = 1
    #expect(throws: (any Error).self) {
      try WorkspaceResourceAddition.add(
        sheet: .videoComponent, draft: draft, devices: [], uiState: state)
    }
    #expect(throws: (any Error).self) {
      try WorkspaceResourceAddition.add(sheet: .vision, draft: draft, devices: [], uiState: state)
    }
    #expect(state.definition.videoComponents.isEmpty)
    #expect(state.definition.visions.isEmpty)
  }

  @Test(arguments: WorkspaceAddComponentKind.allCases)
  func componentUsesDefaultsWithoutPlacingProgramLayers(kind: WorkspaceAddComponentKind) throws {
    let state = WorkspaceUIState(definition: .init(), preferences: .init())
    state.definition.inputDevices = [WorkspaceResourceFactory.makeVideoInput(id: 1, name: "Camera")]
    var program = Ldtx_Workspace_V4_ProgramDefinition()
    program.internalID = 2
    state.definition.programs = [program]
    var draft = WorkspaceAddDraft()
    draft.componentKind = kind
    draft.name = kind.rawValue
    draft.videoInputID = 1
    let id = try WorkspaceResourceAddition.add(
      sheet: .videoComponent, draft: draft, devices: [], uiState: state)
    #expect(state.inspectorSelector == .init(kind: kind.inspectorKind, internalID: id))
    let component = try #require(state.definition.videoComponents.first)
    switch kind {
    case .vfxSource: #expect(component.vfxSource.inputDeviceInternalID == 1)
    case .solidColor: #expect(component.solidColorFill.color.alpha == 1)
    case .linearGradient: #expect(component.linearGradientFill.endX == 1)
    case .radialGradient: #expect(component.radialGradientFill.outerRadius == 0.5)
    case .conicGradient: #expect(component.conicGradientFill.centerX == 0.5)
    case .clock:
      #expect(component.clock.showsSeconds)
      #expect(component.clock.width > 0)
    case .testPattern: #expect(component.testPattern.internalID == id)
    }
    #expect(state.definition.programs == [program])
  }

  @Test func visionReferencesChosenInputAndUsesFiveSecondTrigger() throws {
    let state = WorkspaceUIState(definition: .init(), preferences: .init())
    state.definition.inputDevices = [WorkspaceResourceFactory.makeVideoInput(id: 7, name: "Camera")]
    var draft = WorkspaceAddDraft()
    draft.name = "OCR"
    draft.videoInputID = 7
    let id = try WorkspaceResourceAddition.add(
      sheet: .vision, draft: draft, devices: [], uiState: state)
    let vision = try #require(state.definition.visions.first?.ocrVision)
    #expect(vision.source == .inputDeviceInternalID(7))
    #expect(vision.inputDeviceInternalID == 7)
    #expect(vision.triggers.first?.intervalTrigger.intervalSeconds == 5)
    #expect(state.inspectorSelector == .init(kind: .ocrVision, internalID: id))
  }
}
