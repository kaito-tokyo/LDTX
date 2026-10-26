// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
// SPDX-License-Identifier: Apache-2.0

import LDTXCorelibs
import LDTXWorkspaceAppletModel
@testable import LDTXWorkspaceAppletUI
import LDTXYouTubeRTMPS
import Testing

extension AppUIComponentTestSuite {
  @Suite
  @MainActor
  struct WorkspaceResourceAdditionUnitTestSuite {
    @Test("LUB-1050: Program names are reserved across all resource types")
    func programNamesAreReservedAcrossAllResourceTypes() {
      var definition = Ldtx_Workspace_V4_WorkspaceDefinitionV4()
      definition.audioDevices = [WorkspaceResourceFactory.makeAudioInput(id: 1, name: "Program")]
      definition.videoComponents = [
        WorkspaceResourceFactory.makeVFXSource(id: 2, name: "Program 2")
      ]
      definition.visions = [
        .with {
          $0.vision = .ocrVision(
            .with {
              $0.internalID = 3
              $0.displayName = "Program 3"
            })
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

    @Test("LUB-1050: Vfx requires an available camera with positive dimensions")
    func vfxRequiresAnAvailableCameraWithPositiveDimensions() {
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

    @Test("LUB-1050: Vision rejects generated inputs", arguments: WorkspaceAddVisionKind.allCases)
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

    @Test("LUB-1050: Camera cannot be added as audio device")
    func cameraCannotBeAddedAsAudioDevice() {
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

    @Test("LUB-1050: Audio discovery failure rejects addition")
    func audioDiscoveryFailureRejectsAddition() {
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

    struct AdditionState: Sendable, Codable {
      let state: RecordingStateInput
      let allowed: Bool
    }

    @Test(
      "LUB-1050: Output state determines resource addition availability",
      arguments: [
        AdditionState(state: .idle, allowed: true),
        AdditionState(state: .paused, allowed: true),
        AdditionState(state: .failed, allowed: true),
        AdditionState(state: .starting, allowed: false),
        AdditionState(state: .recording, allowed: false),
        AdditionState(state: .pausing, allowed: false),
        AdditionState(state: .stopping, allowed: false),
      ])
    func additionAvailability(_ data: AdditionState) {
      let state = WorkspaceDocument(definition: .init(), preferences: .init())
      state.isOutputActive = data.state.value.isOutputActive
      var draft = WorkspaceAddDraft()
      draft.componentKind = .solidColor
      draft.name = "Color"
      #expect(
        (WorkspaceResourceAddition.validationMessage(
          sheet: .videoComponent, draft: draft, devices: [], stateService: state) == nil)
          == data.allowed)
    }

    struct DeviceNameInput: Sendable, Codable {
      let input: String
      let expected: String
    }

    @Test(
      "LUB-1050: Audio device addition resolves the supplied display name",
      arguments: [
        DeviceNameInput(input: "", expected: "Microphone"),
        DeviceNameInput(input: "  Voice  ", expected: "Voice"),
      ])
    func deviceNameInput(_ data: DeviceNameInput) throws {
      let state = WorkspaceDocument(definition: .init(), preferences: .init())
      let device = WorkspaceAddDeviceOption(
        id: .coreAudioDevice(uid: "microphone"), name: "Microphone")
      var draft = WorkspaceAddDraft()
      draft.physicalDeviceID = device.id
      draft.name = data.input
      let id = try WorkspaceResourceAddition.add(
        sheet: .device, draft: draft, devices: [device], stateService: state)
      #expect(state.workspaceDefinition.audioDevices.first?.displayName == data.expected)
      #expect(state.inspectorSelector == .init(kind: .audioInputDevice, internalID: id))
    }

    @Test("LUB-1050: Rejected adds leave definition and selection unchanged")
    func rejectedAddsLeaveDefinitionAndSelectionUnchanged() throws {
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

    @Test("LUB-1050: Duplicate names are rejected across resource kinds")
    func duplicateNamesAreRejectedAcrossResourceKinds() throws {
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

    @Test(
      "LUB-1050: Component uses defaults without placing program layers",
      arguments: WorkspaceAddComponentKind.allCases.filter { $0 != .dynamicText })
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
        guard case .vfxSource(let value) = component.videoComponent else {
          Issue.record("Wrong component case")
          return
        }

        #expect(value.internalID == id)
        #expect(value.deviceWidth == 1920)
        #expect(value.deviceHeight == 1080)
      case .solidColor:
        guard case .solidColorFill(let value) = component.videoComponent else {
          Issue.record("Wrong component case")
          return
        }
        #expect(value.extendedSrgbColor?.alpha == 1)
      case .dynamicText:
        guard case .dynamicText(let value) = component.videoComponent else {
          Issue.record("Wrong component case")
          return
        }

        #expect(value.internalID == id)
        #expect(value.width?.double(defaultNumerator: 0, defaultDenominator: 1) == 0.5)
        #expect(value.height?.double(defaultNumerator: 0, defaultDenominator: 1) == 0.1)
        #expect(value.rtfdDocument?.isEmpty == false)
      case .linearGradient:
        guard case .linearGradientFill(let value) = component.videoComponent else {
          Issue.record("Wrong component case")
          return
        }

        #expect(
          value.endX
            == Ldtx_Workspace_V4_Rational32.with {
              $0.num = 1
              $0.den = 1
            })
      case .radialGradient:
        guard case .radialGradientFill(let value) = component.videoComponent else {
          Issue.record("Wrong component case")
          return
        }

        #expect(
          value.outerRadius
            == Ldtx_Workspace_V4_Rational32.with {
              $0.num = 1
              $0.den = 2
            })
      case .conicGradient:
        guard case .conicGradientFill(let value) = component.videoComponent else {
          Issue.record("Wrong component case")
          return
        }

        #expect(
          value.centerX
            == Ldtx_Workspace_V4_Rational32.with {
              $0.num = 1
              $0.den = 2
            })
      case .clock:
        guard case .clock(let value) = component.videoComponent else {
          Issue.record("Wrong component case")
          return
        }

        #expect(value.showsSeconds == true)
        #expect(value.fontSize?.float(defaultNumerator: 0, defaultDenominator: 1) == 48)
      case .testPattern:
        guard case .testPattern(let value) = component.videoComponent else {
          Issue.record("Wrong component case")
          return
        }
        #expect(value.internalID == id)
      }
      #expect(state.workspaceDefinition.programs == [program])
    }

    @Test("LUB-1050: Vision references chosen input and uses five second trigger")
    func visionReferencesChosenInputAndUsesFiveSecondTrigger() throws {
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
      guard case .ocrVision(let vision) = state.workspaceDefinition.visions.first?.vision else {
        Issue.record("Missing OCR")
        return
      }
      guard case .intervalTrigger(let trigger) = vision.triggers.first?.trigger else {
        Issue.record("Missing interval trigger")
        return
      }
      #expect(vision.videoComponentInternalID == 7)
      #expect(
        trigger.intervalSeconds
          == Ldtx_Workspace_V4_Rational32.with {
            $0.num = 5
            $0.den = 1
          })
      #expect(state.inspectorSelector == .init(kind: .ocrVision, internalID: id))
    }
    @Test("LUB-1050: Resource drafts and sidebar start unselected") @MainActor
    func resourceDraftsAndSidebarStartUnselected() {
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
