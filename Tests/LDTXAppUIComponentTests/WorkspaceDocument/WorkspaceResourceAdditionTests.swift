// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
// SPDX-License-Identifier: Apache-2.0

import LDTXProtos
import LDTXWorkspaceAppletModel
@testable import LDTXWorkspaceAppletUI
import LDTXYouTubeRTMPS
import Testing

extension AppUIComponentTestSuite {
  @Suite
  @MainActor
  struct WorkspaceResourceAdditionUnitTestSuite {
    @Test func programNamesAreReservedAcrossAllResourceTypes() {
      var definition = Ldtx_Workspace_V4_WorkspaceDefinitionV4()
      definition.audioDevices = [WorkspaceResourceFactory.makeAudioInput(id: 1, name: "Program")]
      definition.videoComponents = [
        WorkspaceResourceFactory.makeVFXSource(id: 2, name: "Program 2")
      ]
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
      let store = WorkspaceDocument(definition: definition, preferences: .init())
      let inspector = WorkspaceProgramsInspector(
        stateService: store, appletData: WorkspaceAppletData())
      #expect(inspector.uniqueProgramDisplayName("Program") == "Program 5")
      #expect(inspector.uniqueProgramDisplayName("Other") == "Other")
    }

    @Test func vfxRequiresAnAvailableCameraWithPositiveDimensions() {
      let store = WorkspaceDocument()
      var draft = WorkspaceAddDraft()
      draft.name = "Camera"
      let camera = WorkspaceAddDeviceOption(
        id: .avCaptureDevice(uniqueID: "camera"), name: "Camera", width: 1920, height: 1080)
      #expect(
        WorkspaceResourceAddition.validationMessage(
          sheet: .videoComponent, draft: draft, devices: [camera], stateService: store) != nil)
      draft.physicalDeviceID = camera.id
      #expect(
        WorkspaceResourceAddition.validationMessage(
          sheet: .videoComponent, draft: draft, devices: [], stateService: store) != nil)
      var invalidCamera = camera
      invalidCamera.width = 0
      #expect(
        WorkspaceResourceAddition.validationMessage(
          sheet: .videoComponent, draft: draft, devices: [invalidCamera], stateService: store)
          != nil)
      #expect(
        WorkspaceResourceAddition.validationMessage(
          sheet: .videoComponent, draft: draft, devices: [camera], stateService: store) == nil)
    }

    @Test(arguments: WorkspaceAddVisionKind.allCases)
    func visionRejectsGeneratedInputs(kind: WorkspaceAddVisionKind) {
      let store = WorkspaceDocument()
      store.editWorkspace(undoManager: nil) { workspace in
        workspace.definition.videoComponents = [
          WorkspaceResourceFactory.makeSolidColor(id: 1, name: "Fill")
        ]
      }
      var draft = WorkspaceAddDraft()
      draft.name = "Vision"
      draft.visionKind = kind
      draft.videoComponentID = 1
      #expect(throws: (any Error).self) {
        try WorkspaceResourceAddition.add(
          sheet: .vision, draft: draft, devices: [], stateService: store)
      }
      #expect(store.workspaceDefinition.visions.isEmpty)
    }

    @Test func cameraCannotBeAddedAsAudioDevice() {
      let state = WorkspaceDocument(definition: .init(), preferences: .init())
      let camera = WorkspaceAddDeviceOption(
        id: .avCaptureDevice(uniqueID: "camera"), name: "Camera")
      var draft = WorkspaceAddDraft()
      draft.physicalDeviceID = camera.id
      #expect(throws: (any Error).self) {
        try WorkspaceResourceAddition.add(
          sheet: .device, draft: draft, devices: [camera], stateService: state)
      }
      #expect(state.workspaceDefinition.audioDevices.isEmpty)
    }

    @Test func audioDiscoveryFailureRejectsAddition() {
      let state = WorkspaceDocument(definition: .init(), preferences: .init())
      let audio = WorkspaceAddDeviceOption(id: .coreAudioDevice(uid: "audio"), name: "Audio")
      var draft = WorkspaceAddDraft()
      draft.physicalDeviceID = audio.id
      #expect(throws: (any Error).self) {
        try WorkspaceResourceAddition.add(
          sheet: .device, draft: draft, devices: [audio], stateService: state,
          audioDiscoveryError: "Audio discovery failed")
      }
      #expect(state.workspaceDefinition.audioDevices.isEmpty)
    }

    @Test func outputStateLocksDefinitionChangesDuringTransitions() {
      let state = WorkspaceDocument(definition: .init(), preferences: .init())
      var draft = WorkspaceAddDraft()
      draft.componentKind = .solidColor
      draft.name = "Color"
      for value in [WorkspaceRecordingState.starting, .recording, .pausing, .stopping] {
        state.isOutputActive = value.isOutputActive
        #expect(!value.canStart)
        #expect(
          WorkspaceResourceAddition.validationMessage(
            sheet: .videoComponent, draft: draft, devices: [], stateService: state) != nil)
      }
      for value in [WorkspaceRecordingState.idle, .paused, .failed("Failure")] {
        state.isOutputActive = value.isOutputActive
        #expect(value.canStart)
        #expect(
          WorkspaceResourceAddition.validationMessage(
            sheet: .videoComponent, draft: draft, devices: [], stateService: state) == nil)
      }
    }

    @Test func deviceNameFallsBackAndExplicitNameIsTrimmed() throws {
      let state = WorkspaceDocument(definition: .init(), preferences: .init())
      let camera = WorkspaceAddDeviceOption(id: .coreAudioDevice(uid: "camera"), name: "Microphone")
      var draft = WorkspaceAddDraft()
      draft.physicalDeviceID = camera.id
      let id = try WorkspaceResourceAddition.add(
        sheet: .device, draft: draft, devices: [camera], stateService: state)
      #expect(state.workspaceDefinition.audioDevices.first?.displayName == "Microphone")
      #expect(state.inspectorSelector == .init(kind: .audioInputDevice, internalID: id))
      let audio = WorkspaceAddDeviceOption(id: .coreAudioDevice(uid: "camera"), name: "Microphone")
      draft.physicalDeviceID = audio.id
      draft.name = "  Voice  "
      try WorkspaceResourceAddition.add(
        sheet: .device, draft: draft, devices: [audio], stateService: state)
      #expect(state.workspaceDefinition.audioDevices.last?.displayName == "Voice")
      #expect(state.inspectorSelector?.kind == .audioInputDevice)
    }

    @Test func rejectedAddsLeaveDefinitionAndSelectionUnchanged() throws {
      let state = WorkspaceDocument(definition: .init(), preferences: .init())
      var draft = WorkspaceAddDraft()
      draft.componentKind = .solidColor
      draft.name = "  "
      let definition = state.workspaceDefinition
      let selection = state.inspectorSelector
      #expect(throws: (any Error).self) {
        try WorkspaceResourceAddition.add(
          sheet: .videoComponent, draft: draft, devices: [], stateService: state)
      }
      draft.name = "Solid Color"
      state.isOutputActive = true
      #expect(throws: (any Error).self) {
        try WorkspaceResourceAddition.add(
          sheet: .videoComponent, draft: draft, devices: [], stateService: state)
      }
      state.isOutputActive = false
      draft.componentKind = .vfxSource
      draft.videoComponentID = 99
      #expect(throws: (any Error).self) {
        try WorkspaceResourceAddition.add(
          sheet: .vision, draft: draft, devices: [], stateService: state)
      }
      draft.physicalDeviceID = .avCaptureDevice(uniqueID: "disconnected")
      #expect(throws: (any Error).self) {
        try WorkspaceResourceAddition.add(
          sheet: .device, draft: draft, devices: [], stateService: state)
      }
      #expect(state.workspaceDefinition == definition)
      #expect(state.inspectorSelector == selection)
    }

    @Test func duplicateNamesAreRejectedAcrossResourceKinds() throws {
      let state = WorkspaceDocument(definition: .init(), preferences: .init())
      state.editWorkspace(undoManager: nil) { workspace in
        workspace.definition.videoComponents = [
          WorkspaceResourceFactory.makeVFXSource(id: 1, name: "Shared")
        ]
      }
      var draft = WorkspaceAddDraft()
      draft.name = " Shared "
      draft.componentKind = .clock
      draft.videoComponentID = 1
      #expect(throws: (any Error).self) {
        try WorkspaceResourceAddition.add(
          sheet: .videoComponent, draft: draft, devices: [], stateService: state)
      }
      #expect(throws: (any Error).self) {
        try WorkspaceResourceAddition.add(
          sheet: .vision, draft: draft, devices: [], stateService: state)
      }
      #expect(state.workspaceDefinition.videoComponents.count == 1)
      #expect(state.workspaceDefinition.visions.isEmpty)
    }

    @Test(arguments: WorkspaceAddComponentKind.allCases.filter { $0 != .dynamicText })
    func componentUsesDefaultsWithoutPlacingProgramLayers(kind: WorkspaceAddComponentKind) throws {
      let state = WorkspaceDocument(definition: .init(), preferences: .init())
      var program = Ldtx_Workspace_V4_ProgramDefinition()
      program.internalID = 2
      state.editWorkspace(undoManager: nil) { workspace in
        workspace.definition.programs = [program]
      }
      var draft = WorkspaceAddDraft()
      draft.componentKind = kind
      draft.name = kind.rawValue
      draft.videoComponentID = 1
      let camera = WorkspaceAddDeviceOption(
        id: .avCaptureDevice(uniqueID: "camera"), name: "Camera", width: 1920, height: 1080)
      draft.physicalDeviceID = camera.id
      let id = try WorkspaceResourceAddition.add(
        sheet: .videoComponent, draft: draft, devices: [camera], stateService: state)
      #expect(state.inspectorSelector == .init(kind: kind.inspectorKind, internalID: id))
      let component = try #require(state.workspaceDefinition.videoComponents.first)
      switch kind {
      case .vfxSource:
        #expect(component.vfxSource.internalID == id)
        #expect(component.vfxSource.deviceWidth == 1920)
        #expect(component.vfxSource.deviceHeight == 1080)
      case .solidColor: #expect(component.solidColorFill.extendedSrgbColor.alpha == 1)
      case .dynamicText:
        #expect(component.dynamicText.internalID == id)
        #expect(component.dynamicText.width.double == 0.5)
        #expect(component.dynamicText.height.double == 0.1)
        #expect(!component.dynamicText.rtfdDocument.isEmpty)
      case .linearGradient:
        #expect(
          component.linearGradientFill.endX
            == Ldtx_Workspace_V4_Rational32.with {
              $0.num = 1
              $0.den = 1
            })
      case .radialGradient:
        #expect(
          component.radialGradientFill.outerRadius
            == Ldtx_Workspace_V4_Rational32.with {
              $0.num = 1
              $0.den = 2
            })
      case .conicGradient:
        #expect(
          component.conicGradientFill.centerX
            == Ldtx_Workspace_V4_Rational32.with {
              $0.num = 1
              $0.den = 2
            })
      case .clock:
        #expect(component.clock.showsSeconds)
        #expect(component.clock.fontSize.float == 48)
      case .testPattern: #expect(component.testPattern.internalID == id)
      }
      #expect(state.workspaceDefinition.programs == [program])
    }

    @Test func visionReferencesChosenInputAndUsesFiveSecondTrigger() throws {
      let state = WorkspaceDocument(definition: .init(), preferences: .init())
      state.editWorkspace(undoManager: nil) { workspace in
        workspace.definition.videoComponents = [
          WorkspaceResourceFactory.makeVFXSource(id: 7, name: "Camera")
        ]
      }
      var draft = WorkspaceAddDraft()
      draft.name = "OCR"
      draft.videoComponentID = 7
      let id = try WorkspaceResourceAddition.add(
        sheet: .vision, draft: draft, devices: [], stateService: state)
      let vision = try #require(state.workspaceDefinition.visions.first?.ocrVision)
      #expect(vision.videoComponentInternalID == 7)
      #expect(
        vision.triggers.first?.intervalTrigger.intervalSeconds
          == Ldtx_Workspace_V4_Rational32.with {
            $0.num = 5
            $0.den = 1
          })
      #expect(state.inspectorSelector == .init(kind: .ocrVision, internalID: id))
    }
    @Test @MainActor func resourceDraftsAndSidebarStartUnselected() {
      let draft = WorkspaceAddDraft()
      #expect(draft.physicalDeviceID == nil)
      #expect(draft.videoComponentID == nil)
      let state = WorkspaceDocument(definition: .init(), preferences: .init())
      #expect(state.inspectorSelector == nil)
      let before = state.workspaceDefinition
      #expect(
        WorkspaceResourceAddition.validationMessage(
          sheet: .device, draft: draft, devices: [], stateService: state) != nil)
      #expect(
        WorkspaceResourceAddition.validationMessage(
          sheet: .vision, draft: draft, devices: [], stateService: state) != nil)
      #expect(state.workspaceDefinition == before)
    }
  }

}
