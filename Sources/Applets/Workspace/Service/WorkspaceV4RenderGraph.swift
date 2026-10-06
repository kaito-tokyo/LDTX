// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
//
// SPDX-License-Identifier: Apache-2.0

import Foundation
import LDTXProgram
import LDTXProgramRuntime
import LDTXWorkspaceAppletModel
import LDTXWorkspaceAppletStore

/// A renderer-only projection of one V4 Program. This is derived at the
/// rendering boundary and does not mutate persisted state.
public struct WorkspaceV4RenderGraph: Sendable {
  public var composite: CompositeProgramDefinition
  public var layerPreferences: [VideoLayerPreference]
  public var audioPreferences: ProgramPreferences

  public init(
    definition: Ldtx_Workspace_V4_WorkspaceDefinitionV4,
    canvas: WorkspaceProgramCanvasSnapshot
  ) throws {
    let layerIDs = canvas.layerIDs
    let preference = canvas.preferences
    let transforms = preference.videoLayerTransforms
    let hidden = preference.videoLayerHidden
    let components = Self.componentsByInternalID(definition)
    let canvasWidth = Float(canvas.outputProfile.width)
    let canvasHeight = Float(canvas.outputProfile.height)
    var steps: [CompositeProgramStep] = []
    var layerPreferences: [VideoLayerPreference] = []
    for internalID in layerIDs {
      guard
        var component = components[internalID]
      else { throw WorkspaceV4RenderGraphError.missingVideoLayer(internalID) }
      let transform = transforms[internalID] ?? .init()
      let topInsetRational = Self.unitInterval(transform.topInsetRational.float, default: 0)
      let rightInsetRational = Self.unitInterval(
        transform.rightInsetRational.float, default: 0)
      let bottomInsetRational = Self.unitInterval(
        transform.bottomInsetRational.float, default: 0)
      let leftInsetRational = Self.unitInterval(
        transform.leftInsetRational.float, default: 0)
      let translationXRational = Self.unitInterval(
        transform.translationXRational.float, default: 0)
      let translationYRational = Self.unitInterval(
        transform.translationYRational.float, default: 0)
      let scaleX = transform.hasScaleXRational ? transform.scaleXRational.float : 1
      let scaleY = transform.hasScaleYRational ? transform.scaleYRational.float : 1
      let name = "v4-\(internalID)"
      if case .inputCameraDevice(var input) = component {
        input.sourceCropTop = topInsetRational * 100
        input.sourceCropRight = rightInsetRational * 100
        input.sourceCropBottom = bottomInsetRational * 100
        input.sourceCropLeft = leftInsetRational * 100
        input.destinationX = translationXRational * canvasWidth
        input.destinationY = translationYRational * canvasHeight
        input.destinationScaleX = scaleX
        input.destinationScaleY = scaleY
        component = .inputCameraDevice(input)
      }
      if case .clock(var clock) = component {
        clock.destinationX = translationXRational
        clock.destinationY = translationYRational
        clock.destinationWidth *= 1_920 / canvasWidth
        clock.destinationHeight *= 1_080 / canvasHeight
        clock.destinationWidth *= scaleX
        clock.destinationHeight *= scaleY
        component = .clock(clock)
      }
      steps.append(CompositeProgramStep(id: name, component: component))
      layerPreferences.append(
        VideoLayerPreference(
          componentName: name,
          destinationX: translationXRational,
          destinationY: translationYRational,
          destinationScaleX: scaleX,
          destinationScaleY: scaleY,
          isMuted: hidden[internalID] ?? false
        ))
    }
    let audioChannels = Self.audioChannels(definition)
    composite = CompositeProgramDefinition(steps: steps, audioChannels: audioChannels)
    self.layerPreferences = layerPreferences
    var audioPreferences = ProgramPreferences(
      masterVolume: Self.linearGain(
        (preference.hasAudioMasterVolumeDecibels ? preference.audioMasterVolumeDecibels.double : 0))
    )
    let gains = canvas.audioChannelGainsDecibels
    let mutedAudio = preference.audioChannelMuted
    for channel in audioChannels {
      guard case .inputAudioDevice(let input) = channel.component,
        let id = input.inputDeviceID.flatMap({ UInt64($0.dropFirst(3)) })
      else { continue }
      audioPreferences.audioChannelGainsByName[channel.name] = Self.linearGain(
        (gains[id]?.double ?? 0))
      audioPreferences.audioMutedByInputDeviceName[channel.name] = mutedAudio[id] ?? false
    }
    audioPreferences.videoLayersByProgramName["v4-\(canvas.programInternalID)"] = layerPreferences
    self.audioPreferences = audioPreferences
  }

  static func componentsByInternalID(
    _ definition: Ldtx_Workspace_V4_WorkspaceDefinitionV4
  ) -> [UInt64: ProgramComponent] {
    Dictionary(
      uniqueKeysWithValues: definition.videoComponents.compactMap {
        guard let definition = $0.definition else { return nil }
        switch definition {
        case .solidColorFill(let fill):
          return (
            fill.internalID,
            .fillSolidColor(
              FillSolidColorComponent(
                red: fill.color.red, green: fill.color.green, blue: fill.color.blue,
                alpha: fill.color.alpha))
          )
        case .linearGradientFill(let fill):
          return (
            fill.internalID,
            .fillLinearGradient(
              FillLinearGradientComponent(
                startX: fill.startXRational.float, startY: fill.startYRational.float,
                endX: fill.endXRational.float, endY: fill.endYRational.float,
                startRed: fill.startColor.red, startGreen: fill.startColor.green,
                startBlue: fill.startColor.blue, startAlpha: fill.startColor.alpha,
                endRed: fill.endColor.red, endGreen: fill.endColor.green,
                endBlue: fill.endColor.blue, endAlpha: fill.endColor.alpha))
          )
        case .radialGradientFill(let fill):
          return (
            fill.internalID,
            .fillRadialGradient(
              FillRadialGradientComponent(
                centerX: fill.centerXRational.float,
                centerY: fill.centerYRational.float,
                innerRadius: fill.innerRadiusRational.float,
                outerRadius: fill.outerRadiusRational.float, innerRed: fill.innerColor.red,
                innerGreen: fill.innerColor.green, innerBlue: fill.innerColor.blue,
                innerAlpha: fill.innerColor.alpha, outerRed: fill.outerColor.red,
                outerGreen: fill.outerColor.green, outerBlue: fill.outerColor.blue,
                outerAlpha: fill.outerColor.alpha))
          )
        case .conicGradientFill(let fill):
          return (
            fill.internalID,
            .fillConicGradient(
              FillConicGradientComponent(
                centerX: fill.centerXRational.float,
                centerY: fill.centerYRational.float,
                startAngleRadians: fill.startAngleRadiansRational.float,
                startRed: fill.startColor.red,
                startGreen: fill.startColor.green, startBlue: fill.startColor.blue,
                startAlpha: fill.startColor.alpha, endRed: fill.endColor.red,
                endGreen: fill.endColor.green, endBlue: fill.endColor.blue,
                endAlpha: fill.endColor.alpha))
          )
        case .vfxSource(let source):
          return (
            source.internalID,
            .inputCameraDevice(InputDeviceComponent(inputDeviceID: "v4-\(source.internalID)"))
          )
        case .clock(let clock):
          return (
            clock.internalID,
            .clock(
              ClockComponent(
                destinationWidth: clock.widthRational.float,
                destinationHeight: clock.heightRational.float,
                showsSeconds: clock.showsSeconds, uses24HourTime: clock.uses24HourTime,
                foregroundRed: clock.foregroundColor.red,
                foregroundGreen: clock.foregroundColor.green,
                foregroundBlue: clock.foregroundColor.blue,
                foregroundAlpha: clock.foregroundColor.alpha,
                backgroundRed: clock.backgroundColor.red,
                backgroundGreen: clock.backgroundColor.green,
                backgroundBlue: clock.backgroundColor.blue,
                backgroundAlpha: clock.backgroundColor.alpha,
                showsDate: clock.showsDate, usesSystemTimeZone: !clock.hasUtcOffsetMinutes,
                utcOffsetMinutes: clock.utcOffsetMinutes,
                outlines: clock.outlines.map {
                  ClockTextOutline(
                    thickness: $0.thicknessRational.float, color: colorString($0.color))
                }))
          )
        case .testPattern(let pattern): return (pattern.internalID, .testPattern)
        }
      })
  }

  private static func audioChannels(
    _ definition: Ldtx_Workspace_V4_WorkspaceDefinitionV4
  ) -> [ProgramAudioChannel] {
    definition.audioDevices.compactMap {
      let device = $0
      return ProgramAudioChannel(
        name: "v4-\(device.internalID)",
        component: .inputAudioDevice(
          InputAudioDeviceComponent(inputDeviceID: "v4-\(device.internalID)"))
      )
    }
  }

  private static func linearGain(_ decibels: Double) -> Double {
    ProgramPreferences.linearAudioChannelGain(fromDecibels: decibels)
  }

  private static func colorString(_ color: Ldtx_Workspace_V4_ExtendedSrgbColor) -> String {
    return String(
      format: "#%02X%02X%02X%02X", colorComponent(color.red), colorComponent(color.green),
      colorComponent(color.blue), colorComponent(color.alpha))
  }

  private static func colorComponent(_ value: Float) -> Int {
    guard value.isFinite else { return 0 }
    return Int((min(max(value, 0), 1) * 255).rounded())
  }

  private static func unitInterval(_ value: Float, default defaultValue: Float) -> Float {
    guard value.isFinite else { return defaultValue }
    return min(max(value, 0), 1)
  }

}

extension WorkspaceV4RenderGraph {
  /// Builds the runtime configuration from V4 documents and path-local device
  /// assignments. The persisted V4 documents remain authoritative.
  public static func runtimeConfiguration(
    definition: Ldtx_Workspace_V4_WorkspaceDefinitionV4,
    canvas: WorkspaceProgramCanvasSnapshot,
    physicalDeviceIDs: [UInt64: WorkspacePhysicalDeviceID] = [:],
    timeSeconds: Float
  ) throws -> ProgramRuntimeConfiguration {
    try runtimeProjection(
      definition: definition, canvas: canvas,
      physicalDeviceIDs: physicalDeviceIDs, timeSeconds: timeSeconds
    ).configuration
  }

  public static func runtimeProjection(
    definition: Ldtx_Workspace_V4_WorkspaceDefinitionV4,
    canvas: WorkspaceProgramCanvasSnapshot,
    physicalDeviceIDs: [UInt64: WorkspacePhysicalDeviceID] = [:],
    timeSeconds: Float
  ) throws -> WorkspaceV4RuntimeProjection {
    let graph = try Self(definition: definition, canvas: canvas)
    let layerIDs = canvas.layerIDs
    let resolvedProfile = canvas.outputProfile
    let frameRate = canvas.frameRate
    var cameraIDs: [String: String] = [:]
    for wrapper in definition.videoComponents {
      guard case .vfxSource(let source)? = wrapper.definition,
        layerIDs.contains(source.internalID),
        case .avCaptureDevice(let physicalID)? =
          physicalDeviceIDs[source.internalID]
      else { continue }
      cameraIDs["v4-\(source.internalID)"] = physicalID
    }
    var inputDeviceNames: [String: String] = [:]
    for wrapper in definition.videoComponents {
      guard case .vfxSource(let source)? = wrapper.definition, layerIDs.contains(source.internalID)
      else { continue }
      inputDeviceNames["v4-\(source.internalID)"] = source.displayName
    }
    let masterCameraID: String?
    if definition.canvasConfiguration.hasPtsMasterVfxSourceInternalID,
      case .avCaptureDevice(let id)? = physicalDeviceIDs[
        definition.canvasConfiguration.ptsMasterVfxSourceInternalID]
    {
      masterCameraID = id
    } else {
      masterCameraID = nil
    }
    return WorkspaceV4RuntimeProjection(
      configuration: ProgramRuntimeConfiguration(
        composite: graph.composite,
        audioChannels: graph.composite.audioChannels,
        outputProfile: resolvedProfile,
        canvasWidth: resolvedProfile.width,
        canvasHeight: resolvedProfile.height,
        outputWidth: resolvedProfile.width,
        outputHeight: resolvedProfile.height,
        frameRate: frameRate,
        timeSeconds: timeSeconds,
        videoPTSMasterCameraID: masterCameraID,
        cameraIDsByInputKey: cameraIDs,
        inputDeviceNamesByInputKey: inputDeviceNames,
        cameraInputColorOverrides: [:],
        backgroundRemovalInputKeys: backgroundRemovalInputKeys(
          definition: definition, layerIDs: layerIDs),
        videoLayerProgramName: "v4-\(canvas.programInternalID)"
      ),
      preferences: graph.audioPreferences
    )
  }

  /// Projects one component without any Program transforms or visibility preferences.
  static func componentConfiguration(
    definition: Ldtx_Workspace_V4_WorkspaceDefinitionV4, componentID: UInt64,
    physicalDeviceIDs: [UInt64: WorkspacePhysicalDeviceID], width: Int = 1920, height: Int = 1080
  ) throws -> ProgramRuntimeConfiguration {
    guard var component = componentsByInternalID(definition)[componentID] else {
      throw WorkspaceV4RenderGraphError.missingVideoLayer(componentID)
    }
    if case .clock(var clock) = component {
      clock.destinationWidth = 1
      clock.destinationHeight = 1
      component = .clock(clock)
    }
    let key = "v4-\(componentID)"
    var cameraIDs: [String: String] = [:]
    if case .avCaptureDevice(let id)? = physicalDeviceIDs[componentID] {
      cameraIDs[key] = id
    }
    return ProgramRuntimeConfiguration(
      composite: CompositeProgramDefinition(steps: [.init(id: key, component: component)]),
      audioChannels: [], canvasWidth: width, canvasHeight: height,
      outputWidth: width, outputHeight: height, frameRate: 60,
      timeSeconds: Float(ProcessInfo.processInfo.systemUptime), videoPTSMasterCameraID: nil,
      cameraIDsByInputKey: cameraIDs, cameraInputColorOverrides: [:],
      backgroundRemovalInputKeys: backgroundRemovalInputKeys(
        definition: definition, layerIDs: [componentID]))
  }

  private static func backgroundRemovalInputKeys(
    definition: Ldtx_Workspace_V4_WorkspaceDefinitionV4,
    layerIDs: [UInt64]
  ) -> Set<String> {
    Set(
      definition.videoComponents.compactMap { wrapper -> String? in
        guard case .vfxSource(let source)? = wrapper.definition,
          layerIDs.contains(source.internalID),
          source.effects.contains(where: { effect in
            guard case .backgroundRemoval(let removal)? = effect.definition else { return false }
            return removal.model == .mediapipeLandscape
          })
        else { return nil }
        return "v4-\(source.internalID)"
      })
  }
}

public struct WorkspaceV4RuntimeProjection: Sendable {
  public var configuration: ProgramRuntimeConfiguration
  public var preferences: ProgramPreferences
}

public enum WorkspaceV4RenderGraphError: Error, Equatable {
  case missingProgram(UInt64)
  case missingVideoLayer(UInt64)
  case unsupportedOutputProfile(String)
}
