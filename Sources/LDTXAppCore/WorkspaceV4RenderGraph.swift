// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
//
// SPDX-License-Identifier: Apache-2.0

import Foundation
import LDTXProgram
import LDTXProgramRuntime
import LDTXWorkspace

/// A renderer-only projection of one V4 Program. This is derived at the
/// rendering boundary and never becomes a Version 3 Workspace model.
struct WorkspaceV4RenderGraph: Sendable {
  var composite: CompositeProgramDefinition
  var layerPreferences: [VideoLayerPreference]
  var audioPreferences: ProgramPreferences

  init(
    definition: Ldtx_Workspace_V4_WorkspaceDefinitionV4,
    preferences: Ldtx_Workspace_V4_WorkspacePreferencesV4,
    programInternalID: UInt64,
    role: ProgramCanvasRole
  ) throws {
    guard let program = definition.programs.first(where: { $0.internalID == programInternalID }) else {
      throw WorkspaceV4RenderGraphError.missingProgram(programInternalID)
    }
    let layerIDs = role == .landscape
      ? program.landscapeVideoLayerInternalIds : program.portraitVideoLayerInternalIds
    let preference = preferences.programPreferences[programInternalID] ?? .init()
    let transforms = role == .landscape
      ? preference.landscapeVideoLayerTransforms : preference.portraitVideoLayerTransforms
    let muted = role == .landscape
      ? preference.landscapeVideoLayerMuted : preference.portraitVideoLayerMuted
    let components = Self.componentsByInternalID(definition)
    let inputDevices = Self.videoInputDevicesByInternalID(definition)
    var steps: [CompositeProgramStep] = []
    var layerPreferences: [VideoLayerPreference] = []
    for internalID in layerIDs {
      guard let component = components[internalID] ?? inputDevices[internalID].map(Self.inputComponent)
      else { throw WorkspaceV4RenderGraphError.missingVideoLayer(internalID) }
      let transform = transforms[internalID] ?? .init()
      let name = "v4-\(internalID)"
      steps.append(CompositeProgramStep(id: name, component: component))
      layerPreferences.append(VideoLayerPreference(
        componentName: name,
        destinationX: transform.translationX,
        destinationY: transform.translationY,
        destinationScaleX: transform.scaleX == 0 ? 1 : transform.scaleX,
        destinationScaleY: transform.scaleY == 0 ? 1 : transform.scaleY,
        isMuted: muted[internalID] ?? false
      ))
    }
    let audioChannels = Self.audioChannels(definition)
    composite = CompositeProgramDefinition(steps: steps, audioChannels: audioChannels)
    self.layerPreferences = layerPreferences
    var audioPreferences = ProgramPreferences(
      masterVolume: Self.linearGain(
        role == .landscape ? preference.landscapeMasterVolume : preference.portraitMasterVolume
      )
    )
    let gains = role == .landscape
      ? preference.landscapeAudioChannelGains : preference.portraitAudioChannelGains
    let mutedAudio = role == .landscape
      ? preference.landscapeAudioChannelMuted : preference.portraitAudioChannelMuted
    for channel in audioChannels {
      guard case .inputAudioDevice(let input) = channel.component,
        let id = input.inputDeviceID.flatMap({ UInt64($0.dropFirst(3)) })
      else { continue }
      audioPreferences.audioChannelGainsByName[channel.name] = Self.linearGain(gains[id] ?? 0)
      audioPreferences.audioMutedByInputDeviceName[channel.name] = mutedAudio[id] ?? false
    }
    self.audioPreferences = audioPreferences
  }

  private static func videoInputDevicesByInternalID(
    _ definition: Ldtx_Workspace_V4_WorkspaceDefinitionV4
  ) -> [UInt64: Ldtx_Workspace_V4_VideoInputDevice] {
    Dictionary(uniqueKeysWithValues: definition.inputDevices.compactMap {
      guard case .videoDevice(let device)? = $0.definition else { return nil }
      return (device.internalID, device)
    })
  }

  private static func componentsByInternalID(
    _ definition: Ldtx_Workspace_V4_WorkspaceDefinitionV4
  ) -> [UInt64: ProgramComponent] {
    Dictionary(uniqueKeysWithValues: definition.videoComponents.compactMap {
      guard let definition = $0.definition else { return nil }
      switch definition {
      case .solidColorFill(let fill):
        return (fill.internalID, .fillSolidColor(FillSolidColorComponent(
          red: fill.color.red, green: fill.color.green, blue: fill.color.blue, alpha: fill.color.alpha)))
      case .linearGradientFill(let fill):
        return (fill.internalID, .fillLinearGradient(FillLinearGradientComponent(
          startX: fill.startX, startY: fill.startY, endX: fill.endX, endY: fill.endY,
          startRed: fill.startColor.red, startGreen: fill.startColor.green,
          startBlue: fill.startColor.blue, startAlpha: fill.startColor.alpha,
          endRed: fill.endColor.red, endGreen: fill.endColor.green,
          endBlue: fill.endColor.blue, endAlpha: fill.endColor.alpha)))
      case .radialGradientFill(let fill):
        return (fill.internalID, .fillRadialGradient(FillRadialGradientComponent(
          centerX: fill.centerX, centerY: fill.centerY, innerRadius: fill.innerRadius,
          outerRadius: fill.outerRadius, innerRed: fill.innerColor.red,
          innerGreen: fill.innerColor.green, innerBlue: fill.innerColor.blue,
          innerAlpha: fill.innerColor.alpha, outerRed: fill.outerColor.red,
          outerGreen: fill.outerColor.green, outerBlue: fill.outerColor.blue,
          outerAlpha: fill.outerColor.alpha)))
      case .conicGradientFill(let fill):
        return (fill.internalID, .fillConicGradient(FillConicGradientComponent(
          centerX: fill.centerX, centerY: fill.centerY,
          startAngleRadians: fill.startAngleRadians, startRed: fill.startColor.red,
          startGreen: fill.startColor.green, startBlue: fill.startColor.blue,
          startAlpha: fill.startColor.alpha, endRed: fill.endColor.red,
          endGreen: fill.endColor.green, endBlue: fill.endColor.blue,
          endAlpha: fill.endColor.alpha)))
      case .vfxSource(let source):
        return (source.internalID, inputComponent(inputDeviceInternalID: source.inputDeviceInternalID))
      case .clock(let clock):
        return (clock.internalID, .clock(ClockComponent(
          destinationWidth: clock.width, destinationHeight: clock.height,
          showsSeconds: clock.showsSeconds, uses24HourTime: clock.uses24HourTime,
          showsDate: clock.showsDate, usesSystemTimeZone: !clock.hasUtcOffsetMinutes,
          utcOffsetMinutes: clock.utcOffsetMinutes)))
      case .testPattern(let pattern): return (pattern.internalID, .testPattern)
      default: return nil
      }
    })
  }

  private static func inputComponent(_ device: Ldtx_Workspace_V4_VideoInputDevice) -> ProgramComponent {
    inputComponent(inputDeviceInternalID: device.internalID)
  }

  private static func inputComponent(inputDeviceInternalID: UInt64) -> ProgramComponent {
    .inputCameraDevice(InputDeviceComponent(inputDeviceID: "v4-\(inputDeviceInternalID)"))
  }

  private static func audioChannels(
    _ definition: Ldtx_Workspace_V4_WorkspaceDefinitionV4
  ) -> [ProgramAudioChannel] {
    definition.inputDevices.compactMap {
      guard case .audioDevice(let device)? = $0.definition else { return nil }
      return ProgramAudioChannel(
        name: "v4-\(device.internalID)",
        component: .inputAudioDevice(InputAudioDeviceComponent(inputDeviceID: "v4-\(device.internalID)"))
      )
    }
  }

  private static func linearGain(_ decibels: Double) -> Double {
    ProgramPreferences.linearAudioChannelGain(fromDecibels: decibels)
  }
}

extension WorkspaceV4RenderGraph {
  /// Builds the runtime configuration from V4 documents and path-local device
  /// assignments. The Workspace V3 persistence model is not consulted.
  static func runtimeConfiguration(
    definition: Ldtx_Workspace_V4_WorkspaceDefinitionV4,
    preferences: Ldtx_Workspace_V4_WorkspacePreferencesV4,
    localState: WorkspaceLocalState,
    programInternalID: UInt64,
    role: ProgramCanvasRole,
    timeSeconds: Float
  ) throws -> ProgramRuntimeConfiguration {
    try runtimeProjection(
      definition: definition, preferences: preferences, localState: localState,
      programInternalID: programInternalID, role: role, timeSeconds: timeSeconds
    ).configuration
  }

  static func runtimeProjection(
    definition: Ldtx_Workspace_V4_WorkspaceDefinitionV4,
    preferences: Ldtx_Workspace_V4_WorkspacePreferencesV4,
    localState: WorkspaceLocalState,
    programInternalID: UInt64,
    role: ProgramCanvasRole,
    timeSeconds: Float
  ) throws -> WorkspaceV4RuntimeProjection {
    let graph = try Self(
      definition: definition, preferences: preferences,
      programInternalID: programInternalID, role: role)
    let profile = role == .landscape ? ProgramOutputProfile.sdr1080p60 : .sdrPortrait1080p60
    let bitRate = role == .landscape
      ? definition.canvasConfiguration.landscapeVideoBitRate
      : definition.canvasConfiguration.portraitVideoBitRate
    let resolvedProfile = bitRate == 0 ? profile : profile.withVideoBitRate(Int(bitRate))
    let videoDeviceIDs = Self.videoInputDevicesByInternalID(definition)
    let cameraIDs = Dictionary(uniqueKeysWithValues: videoDeviceIDs.keys.compactMap { id in
      localState.videoInputDevicePhysicalIDs[id].map { ("v4-\(id)", $0) }
    })
    let masterCameraID = definition.canvasConfiguration.hasPtsMasterVideoInputDeviceInternalID
      ? localState.videoInputDevicePhysicalIDs[
        definition.canvasConfiguration.ptsMasterVideoInputDeviceInternalID]
      : nil
    return WorkspaceV4RuntimeProjection(
      configuration: ProgramRuntimeConfiguration(
      composite: graph.composite,
      audioChannels: graph.composite.audioChannels,
      outputProfile: resolvedProfile,
      canvasWidth: resolvedProfile.width,
      canvasHeight: resolvedProfile.height,
      outputWidth: resolvedProfile.width,
      outputHeight: resolvedProfile.height,
      frameRate: max(Int(definition.canvasConfiguration.frameRate), 1),
      timeSeconds: timeSeconds,
      videoPTSMasterCameraID: masterCameraID,
      cameraIDsByInputKey: cameraIDs,
      inputDeviceNamesByInputKey: Dictionary(uniqueKeysWithValues: videoDeviceIDs.map {
        ("v4-\($0.key)", $0.value.displayName)
      }),
      cameraInputColorOverrides: [:],
      backgroundRemovalInputKeys: [],
      videoLayerProgramName: "v4-\(programInternalID)"
      ),
      preferences: graph.audioPreferences
    )
  }
}

struct WorkspaceV4RuntimeProjection: Sendable {
  var configuration: ProgramRuntimeConfiguration
  var preferences: ProgramPreferences
}

enum WorkspaceV4RenderGraphError: Error, Equatable {
  case missingProgram(UInt64)
  case missingVideoLayer(UInt64)
}
