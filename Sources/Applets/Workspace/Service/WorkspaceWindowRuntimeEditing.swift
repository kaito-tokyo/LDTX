// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
//
// SPDX-License-Identifier: Apache-2.0

import Foundation
import LDTXCorelibs
@_exported import LDTXWorkspaceAppletModel
import LDTXWorkspaceAppletStore

extension WorkspaceWindowRuntime {
  public func editDefinition(
    _ mutation: (inout Ldtx_Workspace_V4_WorkspaceDefinitionV4) -> Void
  ) throws {
    try editWorkspace { mutation(&$0.definition) }
  }

  @discardableResult
  public func addAudioInputDevice(displayName: String) throws -> Int64 {
    let id = internalIDGenerator.next(in: definition)
    var device = Ldtx_Workspace_V4_AudioInputDevice()
    device.internalID = id
    device.displayName = displayName
    try editWorkspace { $0.definition.audioDevices.append(device) }
    return id
  }

  @discardableResult
  public func addProgram(displayName: String) throws -> Int64 {
    let id = internalIDGenerator.next(in: definition)
    var program = Ldtx_Workspace_V4_ProgramDefinition()
    program.internalID = id
    program.displayName = displayName
    try editWorkspace { $0.definition.programs.append(program) }
    return id
  }

  @discardableResult
  public func addVFXSource(displayName: String) throws -> Int64 {
    let id = internalIDGenerator.next(in: definition)
    var component = Ldtx_Workspace_V4_VfxSourceComponent()
    component.internalID = id
    component.displayName = displayName
    var wrapper = Ldtx_Workspace_V4_VideoComponentWrapper()
    wrapper.videoComponent = .vfxSource(component)
    try editWorkspace { $0.definition.videoComponents.append(wrapper) }
    return id
  }

  @discardableResult
  public func addSolidColorFill(displayName: String, color: Ldtx_Workspace_V4_Color)
    throws -> Int64
  {
    let id = internalIDGenerator.next(in: definition)
    var component = Ldtx_Workspace_V4_FillSolidColorComponent()
    component.internalID = id
    component.displayName = displayName
    component.extendedSrgbColor = color
    var wrapper = Ldtx_Workspace_V4_VideoComponentWrapper()
    wrapper.videoComponent = .solidColorFill(component)
    try editWorkspace { $0.definition.videoComponents.append(wrapper) }
    return id
  }

  @discardableResult
  public func addLinearGradientFill(
    displayName: String, startColor: Ldtx_Workspace_V4_Color,
    endColor: Ldtx_Workspace_V4_Color
  ) throws -> Int64 {
    let id = internalIDGenerator.next(in: definition)
    var component = Ldtx_Workspace_V4_FillLinearGradientComponent()
    component.internalID = id
    component.displayName = displayName
    component.startX = .with {
      $0.set(num: 0, den: 1)
    }
    component.startY = .with {
      $0.set(num: 0, den: 1)
    }
    component.startExtendedSrgbColor = startColor
    component.endX = .with {
      $0.set(num: 1, den: 1)
    }
    component.endY = .with {
      $0.set(num: 1, den: 1)
    }
    component.endExtendedSrgbColor = endColor
    var wrapper = Ldtx_Workspace_V4_VideoComponentWrapper()
    wrapper.videoComponent = .linearGradientFill(component)
    try editWorkspace { $0.definition.videoComponents.append(wrapper) }
    return id
  }

  @discardableResult
  public func addRadialGradientFill(
    displayName: String, innerColor: Ldtx_Workspace_V4_Color,
    outerColor: Ldtx_Workspace_V4_Color
  ) throws -> Int64 {
    let id = internalIDGenerator.next(in: definition)
    var component = Ldtx_Workspace_V4_FillRadialGradientComponent()
    component.internalID = id
    component.displayName = displayName
    component.centerX = .with {
      $0.set(num: 1, den: 2)
    }
    component.centerY = .with {
      $0.set(num: 1, den: 2)
    }
    component.innerRadius = .with {
      $0.set(num: 0, den: 1)
    }
    component.outerRadius = .with {
      $0.set(num: 1, den: 2)
    }
    component.innerExtendedSrgbColor = innerColor
    component.outerExtendedSrgbColor = outerColor
    var wrapper = Ldtx_Workspace_V4_VideoComponentWrapper()
    wrapper.videoComponent = .radialGradientFill(component)
    try editWorkspace { $0.definition.videoComponents.append(wrapper) }
    return id
  }

  @discardableResult
  public func addConicGradientFill(
    displayName: String, startColor: Ldtx_Workspace_V4_Color,
    endColor: Ldtx_Workspace_V4_Color
  ) throws -> Int64 {
    let id = internalIDGenerator.next(in: definition)
    var component = Ldtx_Workspace_V4_FillConicGradientComponent()
    component.internalID = id
    component.displayName = displayName
    component.centerX = .with {
      $0.set(num: 1, den: 2)
    }
    component.centerY = .with {
      $0.set(num: 1, den: 2)
    }
    component.startExtendedSrgbColor = startColor
    component.endExtendedSrgbColor = endColor
    var wrapper = Ldtx_Workspace_V4_VideoComponentWrapper()
    wrapper.videoComponent = .conicGradientFill(component)
    try editWorkspace { $0.definition.videoComponents.append(wrapper) }
    return id
  }

  @discardableResult
  public func addClock(displayName: String) throws -> Int64 {
    let id = internalIDGenerator.next(in: definition)
    var component = Ldtx_Workspace_V4_ClockComponent()
    component.internalID = id
    component.displayName = displayName
    component.fontSize = .with { $0.set(num: 48, den: 1) }
    component.foregroundExtendedSrgbColor = Self.opaqueWhite
    component.showsSeconds = true
    component.uses24HourTime = true
    var wrapper = Ldtx_Workspace_V4_VideoComponentWrapper()
    wrapper.videoComponent = .clock(component)
    try editWorkspace { $0.definition.videoComponents.append(wrapper) }
    return id
  }

  @discardableResult
  public func addTestPattern(displayName: String) throws -> Int64 {
    let id = internalIDGenerator.next(in: definition)
    var component = Ldtx_Workspace_V4_TestPatternComponent()
    component.internalID = id
    component.displayName = displayName
    var wrapper = Ldtx_Workspace_V4_VideoComponentWrapper()
    wrapper.videoComponent = .testPattern(component)
    try editWorkspace { $0.definition.videoComponents.append(wrapper) }
    return id
  }

  @discardableResult
  public func addOcrVision(
    displayName: String, videoComponentInternalID: Int64,
    intervalSeconds: Ldtx_Workspace_V4_Rational32 = .with {
      $0.set(num: 5, den: 1)
    }
  ) throws -> Int64 {
    let id = internalIDGenerator.next(in: definition)
    var trigger = Ldtx_Workspace_V4_IntervalVisionTrigger()
    trigger.intervalSeconds = intervalSeconds
    var triggerWrapper = Ldtx_Workspace_V4_VisionTriggerWrapper()
    triggerWrapper.trigger = .intervalTrigger(trigger)
    var vision = Ldtx_Workspace_V4_OcrVision()
    vision.internalID = id
    vision.displayName = displayName
    vision.videoComponentInternalID = videoComponentInternalID
    vision.videoComponentInternalID = videoComponentInternalID
    vision.triggers = [triggerWrapper]
    var wrapper = Ldtx_Workspace_V4_VisionWrapper()
    wrapper.vision = .ocrVision(vision)
    try editWorkspace { $0.definition.visions.append(wrapper) }
    return id
  }

  public func removeVideoComponent(internalID: Int64) throws {
    try removeResource(internalID, kind: .component)
  }
  public func removeVision(internalID: Int64) throws {
    try removeResource(internalID, kind: .vision)
  }
  public func removeInputDevice(internalID: Int64) throws {
    try removeResource(internalID, kind: .input)
  }

  public func setVideoLayerOrder(
    _ ids: [Int64], forProgramInternalID programID: Int64, target: WorkspaceCanvasTarget
  ) throws {
    try editProgramPreference(programID, target: target) {
      $0.videoLayerInternalIds = ids
    }
  }

  public func setBasicTransform(
    _ transform: Ldtx_Workspace_V4_BasicTransform, forVideoLayerInternalID id: Int64,
    programInternalID: Int64, target: WorkspaceCanvasTarget
  ) throws {
    try editProgramPreference(programInternalID, target: target) {
      $0.videoLayerTransforms[id] = transform
    }
  }

  public func setAudioChannelGain(
    _ value: Ldtx_Workspace_V4_Rational32, forAudioInputDeviceInternalID id: Int64
  ) throws {
    guard
      let value = try? Rational32DecibelEncoding.encode(
        value.double(defaultNumerator: 0, defaultDenominator: 1))
    else {
      throw WorkspaceRuntimeError.invalidAudioChannelGain
    }
    try editWorkspace { workspace in
      workspace.preferences.audioChannelGainsDecibels[id] = value
    }
  }
  public func setAudioChannelMuted(
    _ value: Bool, forAudioInputDeviceInternalID id: Int64, programInternalID: Int64,
    target: WorkspaceCanvasTarget
  ) throws {
    try editProgramPreference(programInternalID, target: target) {
      $0.audioChannelMuted[id] = value
    }
  }
  public func setVideoLayerHidden(
    _ value: Bool, forVideoLayerInternalID id: Int64, programInternalID: Int64,
    target: WorkspaceCanvasTarget
  ) throws {
    try editProgramPreference(programInternalID, target: target) {
      $0.videoLayerHidden[id] = value
    }
  }
  public func setMasterVolume(
    _ value: Ldtx_Workspace_V4_Rational32, programInternalID: Int64, target: WorkspaceCanvasTarget
  )
    throws
  {
    guard
      let value = try? Rational32DecibelEncoding.encode(
        value.double(defaultNumerator: 0, defaultDenominator: 1))
    else {
      throw WorkspaceRuntimeError.invalidAudioMasterVolume
    }
    try editProgramPreference(programInternalID, target: target) {
      $0.audioMasterVolumeDecibels = value
    }
  }

  public func runtimeProjection(programInternalID: Int64, target: WorkspaceCanvasTarget) throws
    -> WorkspaceV4RuntimeProjection
  {
    guard isRunning else { throw CancellationError() }
    let canvas = try WorkspaceProgramCanvasSnapshot(
      definition: definition, preferences: preferences,
      programInternalID: programInternalID, target: target)
    var projection = try WorkspaceV4RenderGraph.runtimeProjection(
      definition: definition, canvas: canvas, physicalDeviceIDs: physicalDeviceIDs,
      timeSeconds: Float(ProcessInfo.processInfo.systemUptime), variableStore: variableStore)
    let producer = overlayProducer(for: target)
    producer.update(configuration: projection.configuration, preferences: projection.preferences)
    projection.configuration.overlayTextures = producer.textures
    return projection
  }

  private static var opaqueWhite: Ldtx_Workspace_V4_Color {
    var color = Ldtx_Workspace_V4_Color()
    color.red = 1
    color.green = 1
    color.blue = 1
    color.alpha = 1
    return color
  }

  private enum ResourceKind { case component, vision, input }
  private func removeResource(_ id: Int64, kind: ResourceKind) throws {
    try editWorkspace { workspace in
      let removedIDs = [id]
      switch kind {
      case .component:
        let definition = workspace.definition
        let usedByProgram = [WorkspaceCanvasTarget.landscape, .portrait].contains { target in
          workspace.preferences[keyPath: target.preferences].values.contains {
            $0.videoLayerInternalIds.contains(id)
          }
        }
        let usedByVision = definition.visions.contains {
          switch $0.vision {
          case .ocrVision(let vision): vision.videoComponentInternalID == id
          case .ldtxSceneDetectorVision(let vision): vision.videoComponentInternalID == id
          case nil: false
          }
        }
        guard !usedByProgram, !usedByVision,
          definition.canvasConfiguration?.ptsMasterVfxSourceInternalID != id
        else { throw WorkspaceRuntimeError.resourceInUse(id) }
        let before = workspace.definition.videoComponents.count
        workspace.definition.videoComponents.removeAll {
          $0.internalID == id
        }
        guard before != workspace.definition.videoComponents.count else {
          throw WorkspaceRuntimeError.missingResource(id)
        }
      case .vision:
        let before = workspace.definition.visions.count
        workspace.definition.visions.removeAll {
          $0.internalID == id
        }
        guard before != workspace.definition.visions.count else {
          throw WorkspaceRuntimeError.missingResource(id)
        }
      case .input:
        let before = workspace.definition.audioDevices.count
        workspace.definition.audioDevices.removeAll {
          $0.internalID == id
        }
        guard before != workspace.definition.audioDevices.count else {
          throw WorkspaceRuntimeError.missingResource(id)
        }

      }
      for removedID in removedIDs {
        workspace.preferences.audioChannelGainsDecibels.removeValue(forKey: removedID)
      }
      for target in [WorkspaceCanvasTarget.landscape, .portrait] {
        for programID in workspace.preferences[keyPath: target.preferences].keys {
          guard var pref = workspace.preferences[keyPath: target.preferences][programID] else {
            continue
          }
          pref.videoLayerInternalIds.removeAll { removedIDs.contains($0) }
          for removedID in removedIDs {
            pref.audioChannelMuted.removeValue(forKey: removedID)
            pref.videoLayerTransforms.removeValue(forKey: removedID)
            pref.videoLayerHidden.removeValue(forKey: removedID)
          }
          workspace.preferences[keyPath: target.preferences][programID] = pref
        }
      }
    }
  }

  private func editProgramPreference(
    _ id: Int64, target: WorkspaceCanvasTarget,
    _ mutation: (inout Ldtx_Workspace_V4_ProgramPreferences) -> Void
  ) throws {
    try editWorkspace { workspace in
      guard workspace.definition.programs.contains(where: { $0.internalID == id }) else {
        throw WorkspaceRuntimeError.missingProgram(id)
      }
      var preference = workspace.preferences[keyPath: target.preferences][id] ?? .init()
      mutation(&preference)
      workspace.preferences[keyPath: target.preferences][id] = preference
    }
  }
}
