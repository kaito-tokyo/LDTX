// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
// SPDX-License-Identifier: Apache-2.0

import LDTXProtos
import LDTXWorkspaceAppletInterface
@testable import LDTXWorkspaceAppletUI
import Testing

@Suite
@MainActor
struct WorkspaceResourceAdditionUnitTestSuite {
  @Test func programNamesAreReservedAcrossAllResourceTypes() {
    var definition = Ldtx_Workspace_V4_WorkspaceDefinitionV4()
    definition.audioDevices = [WorkspaceResourceFactory.makeAudioInput(id: 1, name: "Program")]
    definition.videoComponents = [WorkspaceResourceFactory.makeVFXSource(id: 2, name: "Program 2")]
    definition.visions = [
      .with {
        $0.ocrVision = .with {
          $0.internalID = 3
          $0.displayName = "Program 3"
        }
      }
    ]
    definition.programs = [
      .with {
        $0.internalID = 4
        $0.displayName = "Program 4"
      }
    ]
    let store = WorkspaceStoreService(definition: definition, preferences: .init())
    let inspector = WorkspaceProgramsInspector(
      storeService: store, appletData: WorkspaceAppletData())
    #expect(inspector.uniqueProgramDisplayName("Program") == "Program 5")
    #expect(inspector.uniqueProgramDisplayName("Other") == "Other")
  }

  @Test func cameraCannotBeAddedAsAudioDevice() {
    let state = WorkspaceStoreService(definition: .init(), preferences: .init())
    let camera = WorkspaceAddDeviceOption(id: .avCaptureDevice(uniqueID: "camera"), name: "Camera")
    var draft = WorkspaceAddDraft()
    draft.physicalDeviceID = camera.id
    #expect(throws: (any Error).self) {
      try WorkspaceResourceAddition.add(
        sheet: .device, draft: draft, devices: [camera], storeService: state)
    }
    #expect(state.definition.audioDevices.isEmpty)
  }

  @Test func audioDiscoveryFailureRejectsAddition() {
    let state = WorkspaceStoreService(definition: .init(), preferences: .init())
    let audio = WorkspaceAddDeviceOption(id: .coreAudioDevice(uid: "audio"), name: "Audio")
    var draft = WorkspaceAddDraft()
    draft.physicalDeviceID = audio.id
    #expect(throws: (any Error).self) {
      try WorkspaceResourceAddition.add(
        sheet: .device, draft: draft, devices: [audio], storeService: state,
        audioDiscoveryError: "Audio discovery failed")
    }
    #expect(state.definition.audioDevices.isEmpty)
  }

  @Test func outputStateLocksDefinitionChangesDuringTransitions() {
    let state = WorkspaceStoreService(definition: .init(), preferences: .init())
    var draft = WorkspaceAddDraft()
    draft.componentKind = .solidColor
    draft.name = "Color"
    for value in [WorkspaceRecordingState.starting, .recording, .pausing, .stopping] {
      state.isOutputActive = value.isOutputActive
      #expect(!value.canStart)
      #expect(
        WorkspaceResourceAddition.validationMessage(
          sheet: .videoComponent, draft: draft, devices: [], storeService: state) != nil)
    }
    for value in [WorkspaceRecordingState.idle, .paused, .failed("Failure")] {
      state.isOutputActive = value.isOutputActive
      #expect(value.canStart)
      #expect(
        WorkspaceResourceAddition.validationMessage(
          sheet: .videoComponent, draft: draft, devices: [], storeService: state) == nil)
    }
  }

  @Test func deviceNameFallsBackAndExplicitNameIsTrimmed() throws {
    let state = WorkspaceStoreService(definition: .init(), preferences: .init())
    let camera = WorkspaceAddDeviceOption(id: .coreAudioDevice(uid: "camera"), name: "Microphone")
    var draft = WorkspaceAddDraft()
    draft.physicalDeviceID = camera.id
    let id = try WorkspaceResourceAddition.add(
      sheet: .device, draft: draft, devices: [camera], storeService: state)
    #expect(state.definition.audioDevices.first?.displayName == "Microphone")
    #expect(state.inspectorSelector == .init(kind: .audioInputDevice, internalID: id))
    let audio = WorkspaceAddDeviceOption(id: .coreAudioDevice(uid: "camera"), name: "Microphone")
    draft.physicalDeviceID = audio.id
    draft.name = "  Voice  "
    try WorkspaceResourceAddition.add(
      sheet: .device, draft: draft, devices: [audio], storeService: state)
    #expect(state.definition.audioDevices.last?.displayName == "Voice")
    #expect(state.inspectorSelector?.kind == .audioInputDevice)
  }

  @Test func rejectedAddsLeaveDefinitionAndSelectionUnchanged() throws {
    let state = WorkspaceStoreService(definition: .init(), preferences: .init())
    var draft = WorkspaceAddDraft()
    draft.componentKind = .solidColor
    draft.name = "  "
    let definition = state.definition
    let selection = state.inspectorSelector
    #expect(throws: (any Error).self) {
      try WorkspaceResourceAddition.add(
        sheet: .videoComponent, draft: draft, devices: [], storeService: state)
    }
    draft.name = "Solid Color"
    state.isOutputActive = true
    #expect(throws: (any Error).self) {
      try WorkspaceResourceAddition.add(
        sheet: .videoComponent, draft: draft, devices: [], storeService: state)
    }
    state.isOutputActive = false
    draft.componentKind = .vfxSource
    draft.videoComponentID = 99
    #expect(throws: (any Error).self) {
      try WorkspaceResourceAddition.add(
        sheet: .vision, draft: draft, devices: [], storeService: state)
    }
    draft.physicalDeviceID = .avCaptureDevice(uniqueID: "disconnected")
    #expect(throws: (any Error).self) {
      try WorkspaceResourceAddition.add(
        sheet: .device, draft: draft, devices: [], storeService: state)
    }
    #expect(state.definition == definition)
    #expect(state.inspectorSelector == selection)
  }

  @Test func duplicateNamesAreRejectedAcrossResourceKinds() throws {
    let state = WorkspaceStoreService(definition: .init(), preferences: .init())
    state.definition.videoComponents = [
      WorkspaceResourceFactory.makeVFXSource(id: 1, name: "Shared")
    ]
    var draft = WorkspaceAddDraft()
    draft.name = " Shared "
    draft.componentKind = .clock
    draft.videoComponentID = 1
    #expect(throws: (any Error).self) {
      try WorkspaceResourceAddition.add(
        sheet: .videoComponent, draft: draft, devices: [], storeService: state)
    }
    #expect(throws: (any Error).self) {
      try WorkspaceResourceAddition.add(
        sheet: .vision, draft: draft, devices: [], storeService: state)
    }
    #expect(state.definition.videoComponents.count == 1)
    #expect(state.definition.visions.isEmpty)
  }

  @Test(arguments: WorkspaceAddComponentKind.allCases)
  func componentUsesDefaultsWithoutPlacingProgramLayers(kind: WorkspaceAddComponentKind) throws {
    let state = WorkspaceStoreService(definition: .init(), preferences: .init())
    var program = Ldtx_Workspace_V4_ProgramDefinition()
    program.internalID = 2
    state.definition.programs = [program]
    var draft = WorkspaceAddDraft()
    draft.componentKind = kind
    draft.name = kind.rawValue
    draft.videoComponentID = 1
    let id = try WorkspaceResourceAddition.add(
      sheet: .videoComponent, draft: draft, devices: [], storeService: state)
    #expect(state.inspectorSelector == .init(kind: kind.inspectorKind, internalID: id))
    let component = try #require(state.definition.videoComponents.first)
    switch kind {
    case .vfxSource: #expect(component.vfxSource.internalID == id)
    case .solidColor: #expect(component.solidColorFill.color.alpha == 1)
    case .linearGradient:
      #expect(
        component.linearGradientFill.endXRational
          == Ldtx_Workspace_V4_Rational32.with {
            $0.numerator = 1
            $0.denominator = 1
          })
    case .radialGradient:
      #expect(
        component.radialGradientFill.outerRadiusRational
          == Ldtx_Workspace_V4_Rational32.with {
            $0.numerator = 1
            $0.denominator = 2
          })
    case .conicGradient:
      #expect(
        component.conicGradientFill.centerXRational
          == Ldtx_Workspace_V4_Rational32.with {
            $0.numerator = 1
            $0.denominator = 2
          })
    case .clock:
      #expect(component.clock.showsSeconds)
      #expect(component.clock.widthRational.float > 0)
    case .testPattern: #expect(component.testPattern.internalID == id)
    }
    #expect(state.definition.programs == [program])
  }

  @Test func visionReferencesChosenInputAndUsesFiveSecondTrigger() throws {
    let state = WorkspaceStoreService(definition: .init(), preferences: .init())
    state.definition.videoComponents = [
      WorkspaceResourceFactory.makeVFXSource(id: 7, name: "Camera")
    ]
    var draft = WorkspaceAddDraft()
    draft.name = "OCR"
    draft.videoComponentID = 7
    let id = try WorkspaceResourceAddition.add(
      sheet: .vision, draft: draft, devices: [], storeService: state)
    let vision = try #require(state.definition.visions.first?.ocrVision)
    #expect(vision.source == .videoComponentInternalID(7))
    #expect(vision.videoComponentInternalID == 7)
    #expect(
      vision.triggers.first?.intervalTrigger.intervalSecondsRational
        == Ldtx_Workspace_V4_Rational32.with {
          $0.numerator = 5
          $0.denominator = 1
        })
    #expect(state.inspectorSelector == .init(kind: .ocrVision, internalID: id))
  }
}
