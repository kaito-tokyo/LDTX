// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
//
// SPDX-License-Identifier: Apache-2.0

import Foundation
import LDTXCorelibs
import LDTXProgramRuntime
import LDTXRichText
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
    canvas: WorkspaceProgramCanvasSnapshot,
    variableStore: [LDTXVariableKey: String]? = nil
  ) throws {
    let layerIDs = canvas.layerIDs
    let preference = canvas.preferences
    let transforms = preference.videoLayerTransforms
    let hidden = preference.videoLayerHidden
    let components = Self.componentsByInternalID(definition, variableStore: variableStore)
    let canvasWidth = Float(canvas.outputProfile.width)
    let canvasHeight = Float(canvas.outputProfile.height)
    var steps: [CompositeProgramStep] = []
    var layerPreferences: [VideoLayerPreference] = []
    for internalID in layerIDs {
      guard
        var component = components[internalID]
      else { throw WorkspaceV4RenderGraphError.missingVideoLayer(internalID) }
      let transform = transforms[internalID] ?? .init()
      let topInsetRational = Self.unitInterval(
        (transform.topInset?.float ?? 0), default: 0)
      let rightInsetRational = Self.unitInterval(
        (transform.rightInset?.float ?? 0), default: 0)
      let bottomInsetRational = Self.unitInterval(
        (transform.bottomInset?.float ?? 0), default: 0)
      let leftInsetRational = Self.unitInterval(
        (transform.leftInset?.float ?? 0), default: 0)
      let translationXRational = Self.unitInterval(
        (transform.translationX?.float ?? 0), default: 0
      )
      let translationYRational = Self.unitInterval(
        (transform.translationY?.float ?? 0), default: 0
      )
      let scaleX = (transform.scaleX?.float ?? 1)
      let scaleY = (transform.scaleY?.float ?? 1)
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
        if clock.fontSize == nil {
          clock.destinationWidth *= 1_920 / canvasWidth
          clock.destinationHeight *= 1_080 / canvasHeight
        }
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
          isHidden: hidden[internalID] ?? false
        ))
    }
    let audioChannels = Self.audioChannels(definition)
    composite = CompositeProgramDefinition(steps: steps, audioChannels: audioChannels)
    self.layerPreferences = layerPreferences
    var audioPreferences = ProgramPreferences(
      masterVolume: Self.linearGain(
        (preference.audioMasterVolumeDecibels?.double
          ?? 0))
    )
    let gains = canvas.audioChannelGainsDecibels
    let mutedAudio = preference.audioChannelMuted
    for channel in audioChannels {
      guard case .inputAudioDevice(let input) = channel.component,
        let id = input.inputDeviceID.flatMap({ Int64($0.dropFirst(3)) })
      else { continue }
      audioPreferences.audioChannelGainsByName[channel.name] = Self.linearGain(
        (gains[id]?.double ?? 0))
      audioPreferences.audioMutedByInputDeviceName[channel.name] = mutedAudio[id] ?? false
    }
    audioPreferences.videoLayersByProgramName["v4-\(canvas.programInternalID)"] = layerPreferences
    self.audioPreferences = audioPreferences
  }

  static func componentsByInternalID(
    _ definition: Ldtx_Workspace_V4_WorkspaceDefinitionV4,
    variableStore: [LDTXVariableKey: String]? = nil
  ) -> [Int64: ProgramComponent] {
    Dictionary(
      uniqueKeysWithValues: definition.videoComponents.compactMap {
        wrapper -> (Int64, ProgramComponent)? in
        guard let concrete = wrapper.videoComponent, let id = wrapper.internalID else { return nil }
        switch concrete {
        case .solidColorFill(let fill):
          return (
            id,
            .fillSolidColor(
              FillSolidColorComponent(
                red: (fill.extendedSrgbColor?.red ?? 0),
                green: (fill.extendedSrgbColor?.green ?? 0),
                blue: (fill.extendedSrgbColor?.blue ?? 0),
                alpha: (fill.extendedSrgbColor?.alpha ?? 0)))
          )
        case .linearGradientFill(let fill):
          return (
            id,
            .fillLinearGradient(
              FillLinearGradientComponent(
                startX: (fill.startX?.float ?? 0),
                startY: (fill.startY?.float ?? 0),
                endX: (fill.endX?.float ?? 0),
                endY: (fill.endY?.float ?? 0),
                startRed: (fill.startExtendedSrgbColor?.red ?? 0),
                startGreen: (fill.startExtendedSrgbColor?.green ?? 0),
                startBlue: (fill.startExtendedSrgbColor?.blue ?? 0),
                startAlpha: (fill.startExtendedSrgbColor?.alpha ?? 0),
                endRed: (fill.endExtendedSrgbColor?.red ?? 0),
                endGreen: (fill.endExtendedSrgbColor?.green ?? 0),
                endBlue: (fill.endExtendedSrgbColor?.blue ?? 0),
                endAlpha: (fill.endExtendedSrgbColor?.alpha ?? 0)))
          )
        case .radialGradientFill(let fill):
          return (
            id,
            .fillRadialGradient(
              FillRadialGradientComponent(
                centerX: (fill.centerX?.float ?? 0),
                centerY: (fill.centerY?.float ?? 0),
                innerRadius: (fill.innerRadius?.float
                  ?? 0),
                outerRadius: (fill.outerRadius?.float
                  ?? 0), innerRed: (fill.innerExtendedSrgbColor?.red ?? 0),
                innerGreen: (fill.innerExtendedSrgbColor?.green ?? 0),
                innerBlue: (fill.innerExtendedSrgbColor?.blue ?? 0),
                innerAlpha: (fill.innerExtendedSrgbColor?.alpha ?? 0),
                outerRed: (fill.outerExtendedSrgbColor?.red ?? 0),
                outerGreen: (fill.outerExtendedSrgbColor?.green ?? 0),
                outerBlue: (fill.outerExtendedSrgbColor?.blue ?? 0),
                outerAlpha: (fill.outerExtendedSrgbColor?.alpha ?? 0)))
          )
        case .conicGradientFill(let fill):
          return (
            id,
            .fillConicGradient(
              FillConicGradientComponent(
                centerX: (fill.centerX?.float ?? 0),
                centerY: (fill.centerY?.float ?? 0),
                startAngleRadians: (fill.startAngleRadians?.float ?? 0),
                startRed: (fill.startExtendedSrgbColor?.red ?? 0),
                startGreen: (fill.startExtendedSrgbColor?.green ?? 0),
                startBlue: (fill.startExtendedSrgbColor?.blue ?? 0),
                startAlpha: (fill.startExtendedSrgbColor?.alpha ?? 0),
                endRed: (fill.endExtendedSrgbColor?.red ?? 0),
                endGreen: (fill.endExtendedSrgbColor?.green ?? 0),
                endBlue: (fill.endExtendedSrgbColor?.blue ?? 0),
                endAlpha: (fill.endExtendedSrgbColor?.alpha ?? 0)))
          )
        case .vfxSource(let source):
          return (
            id,
            .inputCameraDevice(InputDeviceComponent(inputDeviceID: "v4-\(id)"))
          )
        case .clock(let clock):
          return (
            id,
            .clock(
              ClockComponent(
                fontSize: (clock.fontSize?.float ?? 48),
                showsSeconds: (clock.showsSeconds ?? false),
                uses24HourTime: (clock.uses24HourTime ?? false),
                foregroundRed: (clock.foregroundExtendedSrgbColor?.red ?? 0),
                foregroundGreen: (clock.foregroundExtendedSrgbColor?.green ?? 0),
                foregroundBlue: (clock.foregroundExtendedSrgbColor?.blue ?? 0),
                foregroundAlpha: (clock.foregroundExtendedSrgbColor?.alpha ?? 0),
                showsDate: (clock.showsDate ?? false),
                usesSystemTimeZone: (clock.utcOffsetMinutes == nil),
                utcOffsetMinutes: clock.utcOffsetMinutes ?? 0,
                outlines: clock.outlines.map {
                  ClockTextOutline(
                    thickness: ($0.thickness?.float ?? 0),
                    color: colorString($0.extendedSrgbColor))
                }))
          )
        case .dynamicText(let text):
          var overlay = ClockComponent(
            destinationWidth: (text.width?.float ?? 0),
            destinationHeight: (text.height?.float ?? 0)
          )
          overlay.resolvedRTFD = text.rtfdDocument
          if let rtfd = text.rtfdDocument, let document = try? LDTXRichTextDocument(rtfd: rtfd),
            let expanded = try? document.expanded(resolve: { reference in
              variableStore?[LDTXVariableKey(id: reference.id, sel: reference.sel)] ?? ""
            }), let resolved = try? LDTXRichTextDocument(expanded)
          {
            overlay.resolvedRTFD = resolved.rtfd
          }
          return (id, .clock(overlay))
        case .testPattern(let pattern): return (id, .testPattern)
        }
      })
  }

  public static func audioChannels(
    _ definition: Ldtx_Workspace_V4_WorkspaceDefinitionV4
  ) -> [ProgramAudioChannel] {
    definition.audioDevices.compactMap {
      let device = $0
      guard let id = device.internalID else { return nil }
      return ProgramAudioChannel(
        name: "v4-\(id)",
        component: .inputAudioDevice(
          InputAudioDeviceComponent(inputDeviceID: "v4-\(id)"))
      )
    }
  }

  public static func monitorPreferences(
    definition: Ldtx_Workspace_V4_WorkspaceDefinitionV4,
    preferences: Ldtx_Workspace_V4_WorkspacePreferencesV4,
    volumeDecibels: Double
  ) -> ProgramPreferences {
    var result = ProgramPreferences(masterVolume: linearGain(volumeDecibels))
    for device in definition.audioDevices {
      guard let id = device.internalID else { continue }
      result.audioChannelGainsByName["v4-\(id)"] =
        linearGain(
          preferences.audioChannelGainsDecibels[id]?.double ?? 0)
    }
    return result
  }

  private static func linearGain(_ decibels: Double) -> Double {
    ProgramPreferences.linearAudioChannelGain(fromDecibels: decibels)
  }

  private static func colorString(_ color: Ldtx_Workspace_V4_Color?) -> String {
    return String(
      format: "#%02X%02X%02X%02X", colorComponent(color?.red ?? 0),
      colorComponent(color?.green ?? 0),
      colorComponent(color?.blue ?? 0), colorComponent(color?.alpha ?? 0))
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
    physicalDeviceIDs: [Int64: WorkspacePhysicalDeviceID] = [:],
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
    physicalDeviceIDs: [Int64: WorkspacePhysicalDeviceID] = [:],
    timeSeconds: Float,
    variableStore: [LDTXVariableKey: String]? = nil
  ) throws -> WorkspaceV4RuntimeProjection {
    let graph = try Self(definition: definition, canvas: canvas, variableStore: variableStore)
    let layerIDs = canvas.layerIDs
    let resolvedProfile = canvas.outputProfile
    let frameRate = canvas.frameRate
    var cameraIDs: [String: String] = [:]
    for wrapper in definition.videoComponents {
      guard case .vfxSource(let source)? = wrapper.videoComponent, let sourceID = source.internalID,
        layerIDs.contains(sourceID),
        case .avCaptureDevice(let physicalID)? =
          physicalDeviceIDs[sourceID]
      else { continue }
      cameraIDs["v4-\(sourceID)"] = physicalID
    }
    var inputDeviceNames: [String: String] = [:]
    for wrapper in definition.videoComponents {
      guard case .vfxSource(let source)? = wrapper.videoComponent, let sourceID = source.internalID,
        layerIDs.contains(sourceID)
      else { continue }
      inputDeviceNames["v4-\(sourceID)"] = source.displayName
    }
    let masterCameraID: String?
    if let masterID = definition.canvasConfiguration?.ptsMasterVfxSourceInternalID,
      case .avCaptureDevice(let id)? = physicalDeviceIDs[
        masterID]
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
    definition: Ldtx_Workspace_V4_WorkspaceDefinitionV4, componentID: Int64,
    physicalDeviceIDs: [Int64: WorkspacePhysicalDeviceID], width: Int = 1920, height: Int = 1080,
    variableStore: [LDTXVariableKey: String]? = nil
  ) throws -> ProgramRuntimeConfiguration {
    guard
      var component = componentsByInternalID(definition, variableStore: variableStore)[componentID]
    else {
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
    layerIDs: [Int64]
  ) -> Set<String> {
    Set(
      definition.videoComponents.compactMap { wrapper -> String? in
        guard case .vfxSource(let source)? = wrapper.videoComponent,
          let sourceID = source.internalID,
          layerIDs.contains(sourceID),
          source.effects.contains(where: { effect in
            guard case .backgroundRemoval(let removal)? = effect.videoEffect else { return false }
            return removal.model == .mediapipeLandscape
          })
        else { return nil }
        return "v4-\(sourceID)"
      })
  }
}

public struct WorkspaceV4RuntimeProjection: Sendable {
  public var configuration: ProgramRuntimeConfiguration
  public var preferences: ProgramPreferences
}

public enum WorkspaceV4RenderGraphError: Error, Equatable {
  case missingProgram(Int64)
  case missingVideoLayer(Int64)
  case unsupportedOutputProfile(String)
}
