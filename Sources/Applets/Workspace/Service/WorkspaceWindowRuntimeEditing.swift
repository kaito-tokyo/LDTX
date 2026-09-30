// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
//
// SPDX-License-Identifier: Apache-2.0

import Foundation
import LDTXCapture
import LDTXProgram
@_exported import LDTXWorkspaceAppletModel
import LDTXWorkspaceAppletStore
import LDTXWorkspaceBundleFormat

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
  public func availableCaptureDevices() -> (
    cameras: [CameraCaptureSource], audioDevices: [AudioCaptureSource]
  ) {
    let service = DefaultCaptureDeviceService()
    return (service.availableCameras(), service.availableAudioDevices())
  }

  public func editDefinition(
    _ mutation: (inout Ldtx_Workspace_V4_WorkspaceDefinitionV4) -> Void
  ) throws {
    try editWorkspace { mutation(&$0.definition) }
  }

  @discardableResult
  public func addVideoInputDevice(displayName: String) throws -> UInt64 {
    let id = internalIDGenerator.next()
    var device = Ldtx_Workspace_V4_VideoInputDevice()
    device.internalID = id
    device.displayName = displayName
    var wrapper = Ldtx_Workspace_V4_InputDeviceWrapper()
    wrapper.videoDevice = device
    try editWorkspace { $0.definition.inputDevices.append(wrapper) }
    return id
  }

  @discardableResult
  public func addAudioInputDevice(displayName: String) throws -> UInt64 {
    let id = internalIDGenerator.next()
    var device = Ldtx_Workspace_V4_AudioInputDevice()
    device.internalID = id
    device.displayName = displayName
    var wrapper = Ldtx_Workspace_V4_InputDeviceWrapper()
    wrapper.audioDevice = device
    try editWorkspace { $0.definition.inputDevices.append(wrapper) }
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
  public func addVFXSource(displayName: String, inputDeviceInternalID: UInt64) throws -> UInt64 {
    let id = internalIDGenerator.next()
    var component = Ldtx_Workspace_V4_VfxSourceComponent()
    component.internalID = id
    component.displayName = displayName
    component.inputDeviceInternalID = inputDeviceInternalID
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
    component.startX = 0
    component.startY = 0
    component.startColor = startColor
    component.endX = 1
    component.endY = 1
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
    component.centerX = 0.5
    component.centerY = 0.5
    component.innerRadius = 0
    component.outerRadius = 0.5
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
    component.centerX = 0.5
    component.centerY = 0.5
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
    component.width = 320 / 1_920
    component.height = 80 / 1_080
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
    displayName: String, inputDeviceInternalID: UInt64, intervalSeconds: Double = 5
  ) throws -> UInt64 {
    let id = internalIDGenerator.next()
    var trigger = Ldtx_Workspace_V4_IntervalVisionTrigger()
    trigger.intervalSeconds = intervalSeconds
    var triggerWrapper = Ldtx_Workspace_V4_VisionTriggerWrapper()
    triggerWrapper.intervalTrigger = trigger
    var vision = Ldtx_Workspace_V4_OcrVision()
    vision.internalID = id
    vision.displayName = displayName
    vision.inputDeviceInternalID = inputDeviceInternalID
    vision.source = .inputDeviceInternalID(inputDeviceInternalID)
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
    _ ids: [UInt64], forProgramInternalID programID: UInt64, role: ProgramCanvasRole
  ) throws {
    try editWorkspace { workspace in
      guard
        let index = workspace.definition.programs.firstIndex(where: { $0.internalID == programID })
      else { throw WorkspaceRuntimeError.missingProgram(programID) }
      switch role {
      case .landscape: workspace.definition.programs[index].landscapeVideoLayerInternalIds = ids
      case .portrait: workspace.definition.programs[index].portraitVideoLayerInternalIds = ids
      }
    }
  }

  public func setBasicTransform(
    _ transform: Ldtx_Workspace_V4_BasicTransform, forVideoLayerInternalID id: UInt64,
    programInternalID: UInt64, role: ProgramCanvasRole
  ) throws {
    try editWorkspace { workspace in
      guard workspace.definition.programs.contains(where: { $0.internalID == programInternalID })
      else { throw WorkspaceRuntimeError.missingProgram(programInternalID) }
      var pref = workspace.preferences.programPreferences[programInternalID] ?? .init()
      switch role {
      case .landscape: pref.landscapeVideoLayerTransforms[id] = transform
      case .portrait: pref.portraitVideoLayerTransforms[id] = transform
      }
      workspace.preferences.programPreferences[programInternalID] = pref
    }
  }

  public func setAudioChannelGain(
    _ value: Double, forAudioInputDeviceInternalID id: UInt64, programInternalID: UInt64,
    role: ProgramCanvasRole
  ) throws {
    try editProgramPreference(programInternalID) {
      switch role {
      case .landscape: $0.landscapeAudioChannelGains[id] = value
      case .portrait: $0.portraitAudioChannelGains[id] = value
      }
    }
  }
  public func setAudioChannelMuted(
    _ value: Bool, forAudioInputDeviceInternalID id: UInt64, programInternalID: UInt64,
    role: ProgramCanvasRole
  ) throws {
    try editProgramPreference(programInternalID) {
      switch role {
      case .landscape: $0.landscapeAudioChannelMuted[id] = value
      case .portrait: $0.portraitAudioChannelMuted[id] = value
      }
    }
  }
  public func setVideoLayerMuted(
    _ value: Bool, forVideoLayerInternalID id: UInt64, programInternalID: UInt64,
    role: ProgramCanvasRole
  ) throws {
    try editProgramPreference(programInternalID) {
      switch role {
      case .landscape: $0.landscapeVideoLayerMuted[id] = value
      case .portrait: $0.portraitVideoLayerMuted[id] = value
      }
    }
  }
  public func setMasterVolume(_ value: Double, programInternalID: UInt64, role: ProgramCanvasRole)
    throws
  {
    try editProgramPreference(programInternalID) {
      switch role {
      case .landscape: $0.landscapeMasterVolume = value
      case .portrait: $0.portraitMasterVolume = value
      }
    }
  }
  public func setMonitorVolume(_ value: Double) throws {
    try editWorkspace { $0.preferences.monitorVolume = value }
  }

  public func runtimeProjection(programInternalID: UInt64, role: ProgramCanvasRole) throws
    -> WorkspaceV4RuntimeProjection
  {
    try persistenceCoordinator.runtimeProjection(
      programInternalID: programInternalID, role: role,
      localState: appletLocalState)
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
      var removedIDs = [id]
      switch kind {
      case .component:
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
        let before = workspace.definition.inputDevices.count
        workspace.definition.inputDevices.removeAll {
          (try? WorkspaceV4IntegrityValidator.inputDeviceID($0)) == id
        }
        guard before != workspace.definition.inputDevices.count else {
          throw WorkspaceRuntimeError.missingResource(id)
        }
        let dependentVFXIDs = Set(
          workspace.definition.videoComponents.compactMap { wrapper -> UInt64? in
            guard case .vfxSource(let source)? = wrapper.definition,
              source.inputDeviceInternalID == id
            else { return nil }
            return source.internalID
          })
        removedIDs.append(contentsOf: dependentVFXIDs)
        workspace.definition.videoComponents.removeAll { wrapper in
          guard case .vfxSource(let source)? = wrapper.definition else { return false }
          return source.inputDeviceInternalID == id
        }
        workspace.definition.visions.removeAll { wrapper in
          guard case .ocrVision(let vision)? = wrapper.definition,
            case .inputDeviceInternalID(let sourceID)? = vision.source
          else { return false }
          return sourceID == id
        }
        if workspace.definition.canvasConfiguration.ptsMasterVideoInputDeviceInternalID == id {
          workspace.definition.canvasConfiguration.clearPtsMasterVideoInputDeviceInternalID()
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
      for programID in workspace.preferences.programPreferences.keys {
        guard var pref = workspace.preferences.programPreferences[programID] else { continue }
        for removedID in removedIDs {
          pref.landscapeAudioChannelGains.removeValue(forKey: removedID)
          pref.portraitAudioChannelGains.removeValue(forKey: removedID)
          pref.landscapeAudioChannelMuted.removeValue(forKey: removedID)
          pref.portraitAudioChannelMuted.removeValue(forKey: removedID)
          pref.landscapeVideoLayerTransforms.removeValue(forKey: removedID)
          pref.portraitVideoLayerTransforms.removeValue(forKey: removedID)
          pref.landscapeVideoLayerMuted.removeValue(forKey: removedID)
          pref.portraitVideoLayerMuted.removeValue(forKey: removedID)
        }
        workspace.preferences.programPreferences[programID] = pref
      }
    }
  }

  private func editProgramPreference(
    _ id: UInt64, _ mutation: (inout Ldtx_Workspace_V4_ProgramPreference) -> Void
  ) throws {
    try editWorkspace { workspace in
      guard workspace.definition.programs.contains(where: { $0.internalID == id }) else {
        throw WorkspaceRuntimeError.missingProgram(id)
      }
      var preference = workspace.preferences.programPreferences[id] ?? .init()
      mutation(&preference)
      workspace.preferences.programPreferences[id] = preference
    }
  }
}
