// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
// SPDX-License-Identifier: Apache-2.0

import LDTXProgram
import LDTXProgramRuntime
import LDTXProtos
import LDTXRichText
import LDTXWorkspaceAppletModel
import LDTXWorkspaceAppletService
@testable import LDTXWorkspaceAppletService
import LDTXWorkspaceAppletStore
import Testing

@MainActor
@Suite("Version 4 Workspace render graph")
struct WorkspaceV4RenderGraphUnitTestSuite {
  @Test func monitorConfigurationDoesNotRequirePrograms() {
    var definition = Ldtx_Workspace_V4_WorkspaceDefinitionV4()
    definition.audioDevices = [.with { $0.internalID = 7 }]
    var preferences = Ldtx_Workspace_V4_WorkspacePreferencesV4()
    preferences.audioChannelGainsDecibels[7] = .with { $0.set(num: -120, den: 10) }
    preferences.landscapeProgramPreferences[99] = .with {
      $0.audioChannelMuted[7] = true
      $0.audioMasterVolumeDecibels = .with { $0.set(num: -600, den: 10) }
    }
    let channels = WorkspaceV4RenderGraph.audioChannels(definition)
    #expect(channels.map(\.name) == ["v4-7"])
    let monitor = WorkspaceV4RenderGraph.monitorPreferences(
      definition: definition, preferences: preferences, volumeDecibels: -6)
    #expect(
      monitor.audioChannelGainsByName["v4-7"]
        == ProgramPreferences.linearAudioChannelGain(fromDecibels: -12))
    #expect(monitor.masterVolume == ProgramPreferences.linearAudioChannelGain(fromDecibels: -6))
    #expect(monitor.audioMutedByInputDeviceName.isEmpty)
    definition.programs = [.with { $0.internalID = 100 }]
    #expect(WorkspaceV4RenderGraph.audioChannels(definition).map(\.name) == channels.map(\.name))
  }

  @Test func distinguishesMissingAndZeroScale() throws {
    var definition = Ldtx_Workspace_V4_WorkspaceDefinitionV4()
    var component = Ldtx_Workspace_V4_VideoComponentWrapper()
    component.testPattern.internalID = 2
    definition.videoComponents = [component]
    var program = Ldtx_Workspace_V4_ProgramDefinition()
    program.internalID = 1
    definition.programs = [program]
    var preferences = Ldtx_Workspace_V4_WorkspacePreferencesV4()
    preferences.landscapeProgramPreferences[1, default: .init()].videoLayerInternalIds = [2]
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
      .videoLayerTransforms[2, default: .init()].scaleX = .with {
        $0.num = 0
        $0.den = 1
      }
    #expect(try graph().layerPreferences.first?.destinationScaleX == 0)
  }

  @Test("Clock font size is independent of the target canvas")
  func preservesClockDimensions() throws {
    var clock = Ldtx_Workspace_V4_ClockComponent()
    clock.internalID = 1
    clock.fontSize = .with { $0.set(num: 48, den: 1) }
    clock.foregroundExtendedSrgbColor = .with { $0.red = 0.25; $0.green = 0.5; $0.blue = 1; $0.alpha = 0.75 }
    var wrapper = Ldtx_Workspace_V4_VideoComponentWrapper()
    wrapper.clock = clock
    var program = Ldtx_Workspace_V4_ProgramDefinition()
    program.internalID = 7
    var definition = Ldtx_Workspace_V4_WorkspaceDefinitionV4()
    definition.programs = [program]
    var preferences = Ldtx_Workspace_V4_WorkspacePreferencesV4()
    preferences.landscapeProgramPreferences[7] = .with { $0.videoLayerInternalIds = [1] }
    preferences.portraitProgramPreferences[7] = .with { $0.videoLayerInternalIds = [1] }
    definition.videoComponents = [wrapper]
    for target in [WorkspaceCanvasTarget.landscape, .portrait] {
      let canvas = try WorkspaceProgramCanvasSnapshot(
        definition: definition, preferences: preferences, programInternalID: 7, target: target)
      let graph = try WorkspaceV4RenderGraph(definition: definition, canvas: canvas)
      guard case .clock(let value) = graph.composite.steps.first?.component else {
        Issue.record("Clock component missing")
        return
      }
      #expect(value.fontSize == 48)
      #expect(value.destinationWidth == 1)
      #expect(value.destinationHeight == 1)
      #expect(value.foregroundRed == 0.25 && value.foregroundGreen == 0.5
        && value.foregroundBlue == 1 && value.foregroundAlpha == 0.75)
    }
  }

  @Test("resolves independent canvas snapshots without sharing preferences")
  func resolvesCanvasSnapshots() throws {
    var program = Ldtx_Workspace_V4_ProgramDefinition()
    program.internalID = 7
    var definition = Ldtx_Workspace_V4_WorkspaceDefinitionV4()
    definition.programs = [program]
    definition.canvasConfiguration.landscapeVideoBitRate = 8_000_000
    definition.canvasConfiguration.portraitVideoBitRate = 4_000_000
    definition.canvasConfiguration.frameRate = 30
    var preferences = Ldtx_Workspace_V4_WorkspacePreferencesV4()
    preferences.landscapeProgramPreferences[7] = .init()
    preferences.landscapeProgramPreferences[7, default: .init()].videoLayerInternalIds = [1, 2]
    preferences.portraitProgramPreferences[7, default: .init()].videoLayerInternalIds = [2, 1]
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
    var definition = Ldtx_Workspace_V4_WorkspaceDefinitionV4()
    definition.programs = [program]
    definition.videoComponents = [input]
    definition.audioDevices = [audio]
    var transform = Ldtx_Workspace_V4_BasicTransform()
    transform.translationX = .with {
      $0.num = 1
      $0.den = 4
    }
    transform.translationY = .with {
      $0.num = 1
      $0.den = 2
    }
    transform.scaleX = .with {
      $0.num = 3
      $0.den = 4
    }
    transform.scaleY = .with {
      $0.num = 3
      $0.den = 5
    }
    var preference = Ldtx_Workspace_V4_ProgramPreferences()
    var portraitPreference = Ldtx_Workspace_V4_ProgramPreferences()
    preference.videoLayerTransforms = [11: transform]
    preference.audioMasterVolumeDecibels = .with {
      $0.num = -16
      $0.den = 5
    }
    preference.audioChannelMuted = [12: true]
    portraitPreference.audioMasterVolumeDecibels = .with {
      $0.num = -91
      $0.den = 10
    }
    portraitPreference.audioChannelMuted = [12: false]
    var preferences = Ldtx_Workspace_V4_WorkspacePreferencesV4()
    preferences.audioChannelGainsDecibels = [
      12: .with {
        $0.num = -123
        $0.den = 10
      }
    ]
    preference.videoLayerInternalIds = [11]
    preferences.landscapeProgramPreferences = [7: preference]
    portraitPreference.videoLayerInternalIds = [11]
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
    var definition = Ldtx_Workspace_V4_WorkspaceDefinitionV4()
    definition.videoComponents = [component]
    definition.programs = [program]
    var preferences = Ldtx_Workspace_V4_WorkspacePreferencesV4()
    preferences.landscapeProgramPreferences[7] = .with { $0.videoLayerInternalIds = [12] }

    let configuration = try WorkspaceV4RenderGraph.runtimeConfiguration(
      definition: definition,
      canvas: try WorkspaceProgramCanvasSnapshot(
        definition: definition, preferences: preferences, programInternalID: 7, target: .landscape),
      timeSeconds: 1)
    let step = try #require(configuration.composite.steps.first)
    let renderingKey = configuration.composite.inputCameraDeviceMappingKey(for: step)
    #expect(configuration.backgroundRemovalInputKeys == [renderingKey])
    let assignedConfiguration = try WorkspaceV4RenderGraph.runtimeProjection(
      definition: definition,
      canvas: try WorkspaceProgramCanvasSnapshot(
        definition: definition, preferences: preferences, programInternalID: 7, target: .landscape),
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
    var definition = Ldtx_Workspace_V4_WorkspaceDefinitionV4()
    definition.programs = [program]
    var preferences = Ldtx_Workspace_V4_WorkspacePreferencesV4()
    preferences.landscapeProgramPreferences[7] = .with {
      $0.videoLayerInternalIds = [20, 21, 22, 23]
    }
    definition.videoComponents = [solidWrapper, linearWrapper, radialWrapper, conicWrapper]

    let graph = try WorkspaceV4RenderGraph(
      definition: definition,
      canvas: try WorkspaceProgramCanvasSnapshot(
        definition: definition, preferences: preferences, programInternalID: 7, target: .landscape))

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
