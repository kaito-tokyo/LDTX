// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
//
// SPDX-License-Identifier: Apache-2.0

import Foundation
import LDTXProgram
@_exported import LDTXWorkspaceAppletModel
import LDTXWorkspaceAppletStore
import LDTXWorkspaceBundleFormat
import SwiftProtobuf

@MainActor
public final class WorkspaceInternalIDGenerator {
  private var randomNumberGenerator = SystemRandomNumberGenerator()

  public init() {}

  public func next(now: Date = Date()) -> UInt64 {
    let milliseconds = UInt64(max(0, now.timeIntervalSince1970 * 1_000))
    let timestamp = (milliseconds & 0x0000_FFFF_FFFF_FFFF) << 15
    return timestamp | UInt64.random(in: 0...0x7fff, using: &randomNumberGenerator)
  }
}

extension WorkspaceWindowRuntime {
  public func editDefinition(
    _ mutation: (inout Ldtx_Workspace_V4_WorkspaceDefinitionV4) -> Void
  ) throws {
    try editWorkspace { mutation(&$0.definition) }
  }

  @discardableResult
  public func addAudioInputDevice(displayName: String) throws -> UInt64 {
    let id = internalIDGenerator.next()
    var device = Ldtx_Workspace_V4_AudioInputDevice()
    device.internalID = id
    device.displayName = displayName
    try editWorkspace { $0.definition.audioDevices.append(device) }
    return id
  }

  @discardableResult
  public func addProgram(displayName: String) throws -> UInt64 {
    let id = internalIDGenerator.next()
    var program = Ldtx_Workspace_V4_ProgramDefinition()
    program.internalID = id
    program.displayName = displayName
    try editWorkspace { $0.definition.programs.append(program) }
    return id
  }

  @discardableResult
  public func addVFXSource(displayName: String) throws -> UInt64 {
    let id = internalIDGenerator.next()
    var component = Ldtx_Workspace_V4_VfxSourceComponent()
    component.internalID = id
    component.displayName = displayName
    var wrapper = Ldtx_Workspace_V4_VideoComponentWrapper()
    wrapper.vfxSource = component
    try editWorkspace { $0.definition.videoComponents.append(wrapper) }
    return id
  }

  @discardableResult
  public func addSolidColorFill(displayName: String, color: Ldtx_Workspace_V4_ExtendedSrgbColor)
    throws -> UInt64
  {
    let id = internalIDGenerator.next()
    var component = Ldtx_Workspace_V4_FillSolidColorComponent()
    component.internalID = id
    component.displayName = displayName
    component.color = color
    var wrapper = Ldtx_Workspace_V4_VideoComponentWrapper()
    wrapper.solidColorFill = component
    try editWorkspace { $0.definition.videoComponents.append(wrapper) }
    return id
  }

  @discardableResult
  public func addLinearGradientFill(
    displayName: String, startColor: Ldtx_Workspace_V4_ExtendedSrgbColor,
    endColor: Ldtx_Workspace_V4_ExtendedSrgbColor
  ) throws -> UInt64 {
    let id = internalIDGenerator.next()
    var component = Ldtx_Workspace_V4_FillLinearGradientComponent()
    component.internalID = id
    component.displayName = displayName
    component.startXRational = .with {
      $0.set(num: 0, den: 1)
    }
    component.startYRational = .with {
      $0.set(num: 0, den: 1)
    }
    component.startColor = startColor
    component.endXRational = .with {
      $0.set(num: 1, den: 1)
    }
    component.endYRational = .with {
      $0.set(num: 1, den: 1)
    }
    component.endColor = endColor
    var wrapper = Ldtx_Workspace_V4_VideoComponentWrapper()
    wrapper.linearGradientFill = component
    try editWorkspace { $0.definition.videoComponents.append(wrapper) }
    return id
  }

  @discardableResult
  public func addRadialGradientFill(
    displayName: String, innerColor: Ldtx_Workspace_V4_ExtendedSrgbColor,
    outerColor: Ldtx_Workspace_V4_ExtendedSrgbColor
  ) throws -> UInt64 {
    let id = internalIDGenerator.next()
    var component = Ldtx_Workspace_V4_FillRadialGradientComponent()
    component.internalID = id
    component.displayName = displayName
    component.centerXRational = .with {
      $0.set(num: 1, den: 2)
    }
    component.centerYRational = .with {
      $0.set(num: 1, den: 2)
    }
    component.innerRadiusRational = .with {
      $0.set(num: 0, den: 1)
    }
    component.outerRadiusRational = .with {
      $0.set(num: 1, den: 2)
    }
    component.innerColor = innerColor
    component.outerColor = outerColor
    var wrapper = Ldtx_Workspace_V4_VideoComponentWrapper()
    wrapper.radialGradientFill = component
    try editWorkspace { $0.definition.videoComponents.append(wrapper) }
    return id
  }

  @discardableResult
  public func addConicGradientFill(
    displayName: String, startColor: Ldtx_Workspace_V4_ExtendedSrgbColor,
    endColor: Ldtx_Workspace_V4_ExtendedSrgbColor
  ) throws -> UInt64 {
    let id = internalIDGenerator.next()
    var component = Ldtx_Workspace_V4_FillConicGradientComponent()
    component.internalID = id
    component.displayName = displayName
    component.centerXRational = .with {
      $0.set(num: 1, den: 2)
    }
    component.centerYRational = .with {
      $0.set(num: 1, den: 2)
    }
    component.startColor = startColor
    component.endColor = endColor
    var wrapper = Ldtx_Workspace_V4_VideoComponentWrapper()
    wrapper.conicGradientFill = component
    try editWorkspace { $0.definition.videoComponents.append(wrapper) }
    return id
  }

  @discardableResult
  public func addClock(displayName: String) throws -> UInt64 {
    let id = internalIDGenerator.next()
    var component = Ldtx_Workspace_V4_ClockComponent()
    component.internalID = id
    component.displayName = displayName
    component.widthRational = .with {
      $0.set(num: 1, den: 6)
    }
    component.heightRational = .with {
      $0.set(num: 2, den: 27)
    }
    component.foregroundColor = Self.opaqueWhite
    var backgroundColor = Ldtx_Workspace_V4_ExtendedSrgbColor()
    backgroundColor.alpha = 0.65
    component.backgroundColor = backgroundColor
    component.showsSeconds = true
    component.uses24HourTime = true
    var wrapper = Ldtx_Workspace_V4_VideoComponentWrapper()
    wrapper.clock = component
    try editWorkspace { $0.definition.videoComponents.append(wrapper) }
    return id
  }

  @discardableResult
  public func addTestPattern(displayName: String) throws -> UInt64 {
    let id = internalIDGenerator.next()
    var component = Ldtx_Workspace_V4_TestPatternComponent()
    component.internalID = id
    component.displayName = displayName
    var wrapper = Ldtx_Workspace_V4_VideoComponentWrapper()
    wrapper.testPattern = component
    try editWorkspace { $0.definition.videoComponents.append(wrapper) }
    return id
  }

  @discardableResult
  public func addOcrVision(
    displayName: String, videoComponentInternalID: UInt64,
    intervalSeconds: Ldtx_Workspace_V4_Rational32 = .with {
      $0.set(num: 5, den: 1)
    }
  ) throws -> UInt64 {
    let id = internalIDGenerator.next()
    var trigger = Ldtx_Workspace_V4_IntervalVisionTrigger()
    trigger.intervalSecondsRational = intervalSeconds
    var triggerWrapper = Ldtx_Workspace_V4_VisionTriggerWrapper()
    triggerWrapper.intervalTrigger = trigger
    var vision = Ldtx_Workspace_V4_OcrVision()
    vision.internalID = id
    vision.displayName = displayName
    vision.videoComponentInternalID = videoComponentInternalID
    vision.source = .videoComponentInternalID(videoComponentInternalID)
    vision.triggers = [triggerWrapper]
    var wrapper = Ldtx_Workspace_V4_VisionWrapper()
    wrapper.ocrVision = vision
    try editWorkspace { $0.definition.visions.append(wrapper) }
    return id
  }

  public func removeVideoComponent(internalID: UInt64) throws {
    try removeResource(internalID, kind: .component)
  }
  public func removeVision(internalID: UInt64) throws {
    try removeResource(internalID, kind: .vision)
  }
  public func removeInputDevice(internalID: UInt64) throws {
    try removeResource(internalID, kind: .input)
  }

  public func setVideoLayerOrder(
    _ ids: [UInt64], forProgramInternalID programID: UInt64, target: WorkspaceCanvasTarget
  ) throws {
    try editWorkspace { workspace in
      guard
        let index = workspace.definition.programs.firstIndex(where: { $0.internalID == programID })
      else { throw WorkspaceRuntimeError.missingProgram(programID) }
      workspace.definition.programs[index][keyPath: target.layerIDs] = ids
    }
  }

  public func setBasicTransform(
    _ transform: Ldtx_Workspace_V4_BasicTransform, forVideoLayerInternalID id: UInt64,
    programInternalID: UInt64, target: WorkspaceCanvasTarget
  ) throws {
    try editProgramPreference(programInternalID, target: target) {
      $0.videoLayerTransforms[id] = transform
    }
  }

  public func setAudioChannelGain(
    _ value: Ldtx_Workspace_V4_Rational32, forAudioInputDeviceInternalID id: UInt64
  ) throws {
    guard let value = try? Rational32DecibelEncoding.encode(value.double) else {
      throw WorkspaceRuntimeError.invalidAudioChannelGain
    }
    try editWorkspace { workspace in
      workspace.preferences.audioChannelGainsDecibels[id] = value
    }
  }
  public func setAudioChannelMuted(
    _ value: Bool, forAudioInputDeviceInternalID id: UInt64, programInternalID: UInt64,
    target: WorkspaceCanvasTarget
  ) throws {
    try editProgramPreference(programInternalID, target: target) {
      $0.audioChannelMuted[id] = value
    }
  }
  public func setVideoLayerHidden(
    _ value: Bool, forVideoLayerInternalID id: UInt64, programInternalID: UInt64,
    target: WorkspaceCanvasTarget
  ) throws {
    try editProgramPreference(programInternalID, target: target) {
      $0.videoLayerHidden[id] = value
    }
  }
  public func setMasterVolume(
    _ value: Ldtx_Workspace_V4_Rational32, programInternalID: UInt64, target: WorkspaceCanvasTarget
  )
    throws
  {
    guard let value = try? Rational32DecibelEncoding.encode(value.double) else {
      throw WorkspaceRuntimeError.invalidAudioMasterVolume
    }
    try editProgramPreference(programInternalID, target: target) {
      $0.audioMasterVolumeDecibels = value
    }
  }

  public func runtimeProjection(programInternalID: UInt64, target: WorkspaceCanvasTarget) throws
    -> WorkspaceV4RuntimeProjection
  {
    try persistenceCoordinator.runtimeProjection(
      programInternalID: programInternalID, target: target,
      localState: appletLocalState, physicalDeviceIDs: physicalDeviceIDs)
  }

  private static var opaqueWhite: Ldtx_Workspace_V4_ExtendedSrgbColor {
    var color = Ldtx_Workspace_V4_ExtendedSrgbColor()
    color.red = 1
    color.green = 1
    color.blue = 1
    color.alpha = 1
    return color
  }

  private enum ResourceKind { case component, vision, input }
  private func removeResource(_ id: UInt64, kind: ResourceKind) throws {
    try editWorkspace { workspace in
      let removedIDs = [id]
      switch kind {
      case .component:
        let definition = workspace.definition
        let usedByProgram = definition.programs.contains {
          $0.landscapeVideoLayerInternalIds.contains(id)
            || $0.portraitVideoLayerInternalIds.contains(id)
        }
        let usedByVision = definition.visions.contains {
          guard case .ocrVision(let vision) = $0.definition else { return false }
          return vision.source == .videoComponentInternalID(id)
        }
        guard !usedByProgram, !usedByVision,
          definition.canvasConfiguration.ptsMasterVfxSourceInternalID != id
        else { throw WorkspaceRuntimeError.resourceInUse(id) }
        let before = workspace.definition.videoComponents.count
        workspace.definition.videoComponents.removeAll {
          (try? WorkspaceV4IntegrityValidator.videoComponentID($0)) == id
        }
        guard before != workspace.definition.videoComponents.count else {
          throw WorkspaceRuntimeError.missingResource(id)
        }
      case .vision:
        let before = workspace.definition.visions.count
        workspace.definition.visions.removeAll {
          (try? WorkspaceV4IntegrityValidator.visionID($0)) == id
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
      for index in workspace.definition.programs.indices {
        workspace.definition.programs[index].landscapeVideoLayerInternalIds.removeAll {
          removedIDs.contains($0)
        }
        workspace.definition.programs[index].portraitVideoLayerInternalIds.removeAll {
          removedIDs.contains($0)
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
    _ id: UInt64, target: WorkspaceCanvasTarget,
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
