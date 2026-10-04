// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
//
// SPDX-License-Identifier: Apache-2.0

import LDTXProtos
import Testing

@Suite("Workspace V4 integrity validation")
struct WorkspaceV4IntegrityValidatorUnitTestSuite {
  @Test("round trips independent canvas preferences through Protobuf")
  func canvasPreferencesRoundTrip() throws {
    var preferences = Ldtx_Workspace_V4_WorkspacePreferencesV4()
    var landscape = Ldtx_Workspace_V4_ProgramPreferences()
    landscape.audioMasterVolumeDecibelTenths = -32
    landscape.audioChannelGainsDecibelTenths[2] = -61
    landscape.videoLayerHidden[3] = true
    var portrait = Ldtx_Workspace_V4_ProgramPreferences()
    portrait.audioMasterVolumeDecibelTenths = 17
    portrait.audioChannelMuted[2] = true
    var transform = Ldtx_Workspace_V4_BasicTransform()
    transform.scaleX = 0.5
    transform.scaleY = 1
    portrait.videoLayerTransforms[3] = transform
    preferences.landscapeProgramPreferences[1] = landscape
    preferences.portraitProgramPreferences[1] = portrait
    let decoded = try Ldtx_Workspace_V4_WorkspacePreferencesV4(
      serializedBytes: preferences.serializedData())
    #expect(decoded == preferences)
    #expect(decoded.landscapeProgramPreferences[1] == landscape)
    #expect(decoded.portraitProgramPreferences[1] == portrait)
  }

  @Test("rejects a Program that references a missing video layer")
  func rejectsMissingVideoLayer() {
    var definition = Ldtx_Workspace_V4_WorkspaceDefinitionV4()
    var program = Ldtx_Workspace_V4_ProgramDefinition()
    program.internalID = 1
    program.landscapeVideoLayerInternalIds = [99]
    definition.programs = [program]

    #expect(throws: WorkspaceV4IntegrityError.missingVideoLayer(99)) {
      try WorkspaceV4IntegrityValidator.validate(definition)
    }
  }

  @Test("rejects a VFX Source that references an audio input device")
  func rejectsAudioInputDeviceForVFXSource() {
    var audioDevice = Ldtx_Workspace_V4_AudioInputDevice()
    audioDevice.internalID = 1
    var input = Ldtx_Workspace_V4_InputDeviceWrapper()
    input.definition = .audioDevice(audioDevice)

    var source = Ldtx_Workspace_V4_VfxSourceComponent()
    source.internalID = 2
    source.inputDeviceInternalID = 1
    var component = Ldtx_Workspace_V4_VideoComponentWrapper()
    component.definition = .vfxSource(source)

    var definition = Ldtx_Workspace_V4_WorkspaceDefinitionV4()
    definition.inputDevices = [input]
    definition.videoComponents = [component]

    #expect(throws: WorkspaceV4IntegrityError.missingVideoInputDevice(1)) {
      try WorkspaceV4IntegrityValidator.validate(definition)
    }
  }

  @Test("rejects entity IDs reused across resource kinds")
  func rejectsCrossKindDuplicateInternalID() {
    var input = Ldtx_Workspace_V4_InputDeviceWrapper()
    input.videoDevice = .with { $0.internalID = 1 }
    var program = Ldtx_Workspace_V4_ProgramDefinition()
    program.internalID = 1
    var definition = Ldtx_Workspace_V4_WorkspaceDefinitionV4()
    definition.inputDevices = [input]
    definition.programs = [program]

    #expect(throws: WorkspaceV4IntegrityError.duplicateInternalID) {
      try WorkspaceV4IntegrityValidator.validate(definition)
    }
  }

  @Test("rejects an OCR Vision without a video input device")
  func rejectsVisionWithMissingVideoInput() {
    var vision = Ldtx_Workspace_V4_OcrVision()
    vision.internalID = 2
    vision.inputDeviceInternalID = 1
    var wrapper = Ldtx_Workspace_V4_VisionWrapper()
    wrapper.ocrVision = vision
    var definition = Ldtx_Workspace_V4_WorkspaceDefinitionV4()
    definition.visions = [wrapper]

    #expect(throws: WorkspaceV4IntegrityError.missingInputDevice(1)) {
      try WorkspaceV4IntegrityValidator.validate(definition)
    }
  }

  @Test("rejects program preferences that reference a missing program", arguments: [false, true])
  func rejectsDanglingProgramPreferences(isPortrait: Bool) {
    var preferences = Ldtx_Workspace_V4_WorkspacePreferencesV4()
    if isPortrait {
      preferences.portraitProgramPreferences[99] = .init()
    } else {
      preferences.landscapeProgramPreferences[99] = .init()
    }
    let workspace = WorkspaceV4Bundle(
      definition: Ldtx_Workspace_V4_WorkspaceDefinitionV4(),
      preferences: preferences
    )

    #expect(throws: WorkspaceV4IntegrityError.missingProgram(99)) {
      try WorkspaceV4IntegrityValidator.validate(workspace)
    }
  }

  @Test("rejects an unsupported output profile")
  func rejectsUnsupportedOutputProfile() {
    var definition = Ldtx_Workspace_V4_WorkspaceDefinitionV4()
    definition.canvasConfiguration.landscapeProfileID = "custom-4k"

    #expect(throws: WorkspaceV4IntegrityError.unsupportedOutputProfile("custom-4k")) {
      try WorkspaceV4IntegrityValidator.validate(definition)
    }
  }

  @Test("rejects an internal ID with the sign bit set")
  func rejectsInternalIDWithSignBit() {
    var definition = Ldtx_Workspace_V4_WorkspaceDefinitionV4()
    var program = Ldtx_Workspace_V4_ProgramDefinition()
    program.internalID = UInt64(1) << 63
    definition.programs = [program]

    #expect(throws: WorkspaceV4IntegrityError.invalidInternalID) {
      try WorkspaceV4IntegrityValidator.validate(definition)
    }
  }

  @Test("rejects duplicate video layers in one Program")
  func rejectsDuplicateVideoLayers() {
    var video = Ldtx_Workspace_V4_VideoInputDevice()
    video.internalID = 1
    var input = Ldtx_Workspace_V4_InputDeviceWrapper()
    input.videoDevice = video
    var program = Ldtx_Workspace_V4_ProgramDefinition()
    program.internalID = 2
    program.landscapeVideoLayerInternalIds = [1, 1]
    var definition = Ldtx_Workspace_V4_WorkspaceDefinitionV4()
    definition.inputDevices = [input]
    definition.programs = [program]

    #expect(throws: WorkspaceV4IntegrityError.duplicateVideoLayer(2)) {
      try WorkspaceV4IntegrityValidator.validate(definition)
    }
  }
}
