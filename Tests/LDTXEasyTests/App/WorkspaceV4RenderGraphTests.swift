// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
// SPDX-License-Identifier: Apache-2.0

import LDTXProgram
import LDTXProgramRuntime
import LDTXWorkspaceAppletModel
import LDTXWorkspaceAppletService
@testable import LDTXWorkspaceAppletService
import LDTXWorkspaceAppletStore
import Testing

@MainActor
@Suite("Version 4 Workspace render graph")
struct WorkspaceV4RenderGraphUnitTestSuite {
  @Test func distinguishesMissingAndZeroScale() throws {
    var definition = Ldtx_Workspace_V4_WorkspaceDefinitionV4()
    var component = Ldtx_Workspace_V4_VideoComponentWrapper()
    component.testPattern.internalID = 2
    definition.videoComponents = [component]
    var program = Ldtx_Workspace_V4_ProgramDefinition()
    program.internalID = 1
    program.landscapeVideoLayerInternalIds = [2]
    definition.programs = [program]
    var preferences = Ldtx_Workspace_V4_WorkspacePreferencesV4()
    func graph() throws -> WorkspaceV4RenderGraph {
      try WorkspaceV4RenderGraph(
        definition: definition,
        canvas:
          WorkspaceProgramCanvasSnapshot(
            definition: definition, preferences: preferences,
            programInternalID: 1, target: .landscape))
    }
    #expect(try graph().layerPreferences.first?.destinationScaleX == 1)
    preferences.landscapeProgramPreferences[1, default: .init()]
      .videoLayerTransforms[2, default: .init()].scaleXRational = .with {
        $0.numerator = 0
        $0.denominator = 1
      }
    #expect(try graph().layerPreferences.first?.destinationScaleX == 0)
  }

  @Test("clock dimensions preserve the same pixel size on both canvases")
  func preservesClockDimensions() throws {
    var clock = Ldtx_Workspace_V4_ClockComponent()
    clock.internalID = 1
    clock.widthRational = .with {
      $0.numerator = 1
      $0.denominator = 6
    }
    clock.heightRational = .with {
      $0.numerator = 2
      $0.denominator = 27
    }
    var wrapper = Ldtx_Workspace_V4_VideoComponentWrapper()
    wrapper.clock = clock
    var program = Ldtx_Workspace_V4_ProgramDefinition()
    program.internalID = 7
    program.landscapeVideoLayerInternalIds = [1]
    program.portraitVideoLayerInternalIds = [1]
    var definition = Ldtx_Workspace_V4_WorkspaceDefinitionV4()
    definition.programs = [program]
    definition.videoComponents = [wrapper]
    for target in [WorkspaceCanvasTarget.landscape, .portrait] {
      let canvas = try WorkspaceProgramCanvasSnapshot(
        definition: definition, preferences: .init(), programInternalID: 7, target: target)
      let graph = try WorkspaceV4RenderGraph(definition: definition, canvas: canvas)
      guard case .clock(let value) = graph.composite.steps.first?.component else {
        Issue.record("Clock component missing")
        return
      }
      #expect(abs(value.destinationWidth * Float(canvas.outputProfile.width) - 320) < 0.001)
      #expect(abs(value.destinationHeight * Float(canvas.outputProfile.height) - 80) < 0.001)
    }
  }

  @Test("resolves independent canvas snapshots without sharing preferences")
  func resolvesCanvasSnapshots() throws {
    var program = Ldtx_Workspace_V4_ProgramDefinition()
    program.internalID = 7
    program.landscapeVideoLayerInternalIds = [1, 2]
    program.portraitVideoLayerInternalIds = [2, 1]
    var definition = Ldtx_Workspace_V4_WorkspaceDefinitionV4()
    definition.programs = [program]
    definition.canvasConfiguration.landscapeVideoBitRate = 8_000_000
    definition.canvasConfiguration.portraitVideoBitRate = 4_000_000
    definition.canvasConfiguration.frameRate = 30
    var preferences = Ldtx_Workspace_V4_WorkspacePreferencesV4()
    preferences.landscapeProgramPreferences[7] = .init()
    preferences.landscapeProgramPreferences[7]?.videoLayerHidden[1] = true
    let landscape = try WorkspaceProgramCanvasSnapshot(
      definition: definition, preferences: preferences, programInternalID: 7, target: .landscape)
    let portrait = try WorkspaceProgramCanvasSnapshot(
      definition: definition, preferences: preferences, programInternalID: 7, target: .portrait)
    #expect(landscape.layerIDs == [1, 2])
    #expect(portrait.layerIDs == [2, 1])
    #expect(landscape.preferences.videoLayerHidden[1] == true)
    #expect(portrait.preferences.videoLayerHidden.isEmpty)
    #expect(landscape.outputProfile.width == 1920)
    #expect(portrait.outputProfile.height == 1920)
    #expect(landscape.outputProfile.videoBitRate == 8_000_000)
    #expect(portrait.outputProfile.videoBitRate == 4_000_000)
    #expect(landscape.frameRate == 30 && portrait.frameRate == 30)
  }

  @Test("projects V4 layer IDs and transforms directly for rendering")
  func projectsV4RenderGraph() throws {
    var video = Ldtx_Workspace_V4_VfxSourceComponent()
    video.internalID = 11
    var input = Ldtx_Workspace_V4_VideoComponentWrapper()
    input.vfxSource = video
    var audio = Ldtx_Workspace_V4_AudioInputDevice()
    audio.internalID = 12
    var program = Ldtx_Workspace_V4_ProgramDefinition()
    program.internalID = 7
    program.landscapeVideoLayerInternalIds = [11]
    program.portraitVideoLayerInternalIds = [11]
    var definition = Ldtx_Workspace_V4_WorkspaceDefinitionV4()
    definition.programs = [program]
    definition.videoComponents = [input]
    definition.audioDevices = [audio]
    var transform = Ldtx_Workspace_V4_BasicTransform()
    transform.translationXRational = .with {
      $0.numerator = 1
      $0.denominator = 4
    }
    transform.translationYRational = .with {
      $0.numerator = 1
      $0.denominator = 2
    }
    transform.scaleXRational = .with {
      $0.numerator = 3
      $0.denominator = 4
    }
    transform.scaleYRational = .with {
      $0.numerator = 3
      $0.denominator = 5
    }
    var preference = Ldtx_Workspace_V4_ProgramPreferences()
    var portraitPreference = Ldtx_Workspace_V4_ProgramPreferences()
    preference.videoLayerTransforms = [11: transform]
    preference.audioMasterVolumeDecibels = .with {
      $0.numerator = -16
      $0.denominator = 5
    }
    preference.audioChannelMuted = [12: true]
    portraitPreference.audioMasterVolumeDecibels = .with {
      $0.numerator = -91
      $0.denominator = 10
    }
    portraitPreference.audioChannelMuted = [12: false]
    var preferences = Ldtx_Workspace_V4_WorkspacePreferencesV4()
    preferences.audioChannelGainsDecibels = [
      12: .with {
        $0.numerator = -123
        $0.denominator = 10
      }
    ]
    preferences.landscapeProgramPreferences = [7: preference]
    preferences.portraitProgramPreferences = [7: portraitPreference]

    let graph = try WorkspaceV4RenderGraph(
      definition: definition,
      canvas: try WorkspaceProgramCanvasSnapshot(
        definition: definition, preferences: preferences, programInternalID: 7, target: .landscape))

    #expect(graph.composite.steps.map(\.name) == ["v4-11"])
    #expect(graph.layerPreferences.first?.destinationX == 0.25)
    #expect(graph.layerPreferences.first?.destinationScaleY == 0.6)
    #expect(graph.composite.audioChannels.map(\.name) == ["v4-12"])
    #expect(
      graph.audioPreferences.masterVolume
        == ProgramPreferences.linearAudioChannelGain(fromDecibels: -3.2))
    #expect(
      graph.audioPreferences.audioChannelGainsByName["v4-12"]
        == ProgramPreferences.linearAudioChannelGain(fromDecibels: -12.3))
    #expect(graph.audioPreferences.audioMutedByInputDeviceName["v4-12"] == true)

    let portraitGraph = try WorkspaceV4RenderGraph(
      definition: definition,
      canvas: try WorkspaceProgramCanvasSnapshot(
        definition: definition, preferences: preferences, programInternalID: 7, target: .portrait))
    #expect(
      portraitGraph.audioPreferences.masterVolume
        == ProgramPreferences.linearAudioChannelGain(fromDecibels: -9.1))
    #expect(
      portraitGraph.audioPreferences.audioChannelGainsByName["v4-12"]
        == ProgramPreferences.linearAudioChannelGain(fromDecibels: -12.3))
    #expect(portraitGraph.audioPreferences.audioMutedByInputDeviceName["v4-12"] == false)

    let configuration = try WorkspaceV4RenderGraph.runtimeConfiguration(
      definition: definition,
      canvas: try WorkspaceProgramCanvasSnapshot(
        definition: definition, preferences: preferences, programInternalID: 7, target: .landscape),
      physicalDeviceIDs: [
        11: .avCaptureDevice(uniqueID: "camera-id")
      ], timeSeconds: 1)
    #expect(configuration.cameraIDsByInputKey == ["v4-11": "camera-id"])
    #expect(configuration.composite.steps.map(\.name) == ["v4-11"])
    #expect(configuration.frameRate == ProgramOutputProfile.sdr1080p60.frameRate)

    let mismatchedDeviceConfiguration = try WorkspaceV4RenderGraph.runtimeConfiguration(
      definition: definition,
      canvas: try WorkspaceProgramCanvasSnapshot(
        definition: definition, preferences: preferences, programInternalID: 7, target: .landscape),
      physicalDeviceIDs: [
        11: .coreAudioDevice(uid: "microphone-instead-of-camera")
      ], timeSeconds: 1)
    #expect(mismatchedDeviceConfiguration.cameraIDsByInputKey.isEmpty)
  }

  @Test("projects a V4 background-removal VFX effect into the runtime")
  func projectsBackgroundRemovalEffect() throws {
    var removal = Ldtx_Workspace_V4_BackgroundRemovalVfxEffect()
    removal.model = .mediapipeLandscape
    var effect = Ldtx_Workspace_V4_VideoEffectWrapper()
    effect.backgroundRemoval = removal
    var source = Ldtx_Workspace_V4_VfxSourceComponent()
    source.internalID = 12
    source.effects = [effect]
    var component = Ldtx_Workspace_V4_VideoComponentWrapper()
    component.vfxSource = source
    var program = Ldtx_Workspace_V4_ProgramDefinition()
    program.internalID = 7
    program.landscapeVideoLayerInternalIds = [12]
    var definition = Ldtx_Workspace_V4_WorkspaceDefinitionV4()
    definition.videoComponents = [component]
    definition.programs = [program]

    let configuration = try WorkspaceV4RenderGraph.runtimeConfiguration(
      definition: definition,
      canvas: try WorkspaceProgramCanvasSnapshot(
        definition: definition, preferences: .init(), programInternalID: 7, target: .landscape),
      timeSeconds: 1)
    let step = try #require(configuration.composite.steps.first)
    let renderingKey = configuration.composite.inputCameraDeviceMappingKey(for: step)
    #expect(configuration.backgroundRemovalInputKeys == [renderingKey])
    let assignedConfiguration = try WorkspaceV4RenderGraph.runtimeProjection(
      definition: definition,
      canvas: try WorkspaceProgramCanvasSnapshot(
        definition: definition, preferences: .init(), programInternalID: 7, target: .landscape),
      physicalDeviceIDs: [12: .avCaptureDevice(uniqueID: "camera")], timeSeconds: 1
    ).configuration
    #expect(assignedConfiguration.cameraIDsByInputKey[renderingKey] == "camera")
  }

  @Test("projects every V4 fill component into the rendering graph")
  func projectsFillComponents() throws {
    var solid = Ldtx_Workspace_V4_FillSolidColorComponent()
    solid.internalID = 20
    var solidWrapper = Ldtx_Workspace_V4_VideoComponentWrapper()
    solidWrapper.solidColorFill = solid

    var linear = Ldtx_Workspace_V4_FillLinearGradientComponent()
    linear.internalID = 21
    var linearWrapper = Ldtx_Workspace_V4_VideoComponentWrapper()
    linearWrapper.linearGradientFill = linear

    var radial = Ldtx_Workspace_V4_FillRadialGradientComponent()
    radial.internalID = 22
    var radialWrapper = Ldtx_Workspace_V4_VideoComponentWrapper()
    radialWrapper.radialGradientFill = radial

    var conic = Ldtx_Workspace_V4_FillConicGradientComponent()
    conic.internalID = 23
    var conicWrapper = Ldtx_Workspace_V4_VideoComponentWrapper()
    conicWrapper.conicGradientFill = conic

    var program = Ldtx_Workspace_V4_ProgramDefinition()
    program.internalID = 7
    program.landscapeVideoLayerInternalIds = [20, 21, 22, 23]
    var definition = Ldtx_Workspace_V4_WorkspaceDefinitionV4()
    definition.programs = [program]
    definition.videoComponents = [solidWrapper, linearWrapper, radialWrapper, conicWrapper]

    let graph = try WorkspaceV4RenderGraph(
      definition: definition,
      canvas: try WorkspaceProgramCanvasSnapshot(
        definition: definition, preferences: .init(), programInternalID: 7, target: .landscape))

    #expect(graph.composite.steps.map(\.name) == ["v4-20", "v4-21", "v4-22", "v4-23"])
    #expect(
      graph.composite.steps.map { step in
        switch step.component {
        case .fillSolidColor: "solid"
        case .fillLinearGradient: "linear"
        case .fillRadialGradient: "radial"
        case .fillConicGradient: "conic"
        default: "other"
        }
      } == ["solid", "linear", "radial", "conic"])
  }

}
