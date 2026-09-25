// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
//
// SPDX-License-Identifier: Apache-2.0

import LDTXCapture
import LDTXProgram
@_exported import LDTXWorkspaceAppletModel
import LDTXWorkspaceAppletStore
import LDTXYouTubeRTMPS

extension WorkspaceV4SessionService {
  public func availableCaptureDevices() -> (
    cameras: [CameraCaptureSource], audioDevices: [AudioCaptureSource]
  ) {
    let service = DefaultCaptureDeviceService()
    return (service.availableCameras(), service.availableAudioDevices())
  }

  public var definition: Ldtx_Workspace_V4_WorkspaceDefinitionV4 {
    store.workspace.definition.definition
  }

  public var preferences: Ldtx_Workspace_V4_WorkspacePreferencesV4 {
    store.workspace.preferences.preferences
  }

  public func editDefinition(
    _ mutation: (inout Ldtx_Workspace_V4_WorkspaceDefinitionV4) -> Void
  ) throws {
    try store.editDefinition(mutation)
  }

  @discardableResult
  public func addVideoInputDevice(displayName: String) throws -> UInt64 {
    try store.addVideoInputDevice(displayName: displayName)
  }

  @discardableResult
  public func addAudioInputDevice(displayName: String) throws -> UInt64 {
    try store.addAudioInputDevice(displayName: displayName)
  }

  @discardableResult
  public func addProgram(displayName: String) throws -> UInt64 {
    try store.addProgram(displayName: displayName)
  }

  @discardableResult
  public func addVFXSource(displayName: String, inputDeviceInternalID: UInt64) throws -> UInt64 {
    try store.addVFXSource(
      displayName: displayName, inputDeviceInternalID: inputDeviceInternalID)
  }

  @discardableResult
  public func addSolidColorFill(
    displayName: String,
    color: Ldtx_Workspace_V4_ExtendedSrgbColor = .init()
  ) throws -> UInt64 {
    try store.addSolidColorFill(displayName: displayName, color: color)
  }

  @discardableResult
  public func addLinearGradientFill(
    displayName: String,
    startColor: Ldtx_Workspace_V4_ExtendedSrgbColor = WorkspaceStore.defaultOpaqueColor,
    endColor: Ldtx_Workspace_V4_ExtendedSrgbColor = WorkspaceStore.defaultGradientEndColor
  ) throws -> UInt64 {
    try store.addLinearGradientFill(
      displayName: displayName, startColor: startColor, endColor: endColor)
  }

  @discardableResult
  public func addRadialGradientFill(
    displayName: String,
    innerColor: Ldtx_Workspace_V4_ExtendedSrgbColor = WorkspaceStore.defaultOpaqueColor,
    outerColor: Ldtx_Workspace_V4_ExtendedSrgbColor = WorkspaceStore.defaultGradientEndColor
  ) throws -> UInt64 {
    try store.addRadialGradientFill(
      displayName: displayName, innerColor: innerColor, outerColor: outerColor)
  }

  @discardableResult
  public func addConicGradientFill(
    displayName: String,
    startColor: Ldtx_Workspace_V4_ExtendedSrgbColor = WorkspaceStore.defaultOpaqueColor,
    endColor: Ldtx_Workspace_V4_ExtendedSrgbColor = WorkspaceStore.defaultGradientEndColor
  ) throws -> UInt64 {
    try store.addConicGradientFill(
      displayName: displayName, startColor: startColor, endColor: endColor)
  }

  @discardableResult
  public func addClock(displayName: String) throws -> UInt64 {
    try store.addClock(displayName: displayName)
  }

  @discardableResult
  public func addTestPattern(displayName: String) throws -> UInt64 {
    try store.addTestPattern(displayName: displayName)
  }

  @discardableResult
  public func addOcrVision(
    displayName: String,
    inputDeviceInternalID: UInt64,
    intervalSeconds: Double = 5
  ) throws -> UInt64 {
    try store.addOcrVision(
      displayName: displayName,
      inputDeviceInternalID: inputDeviceInternalID,
      intervalSeconds: intervalSeconds)
  }

  public func removeInputDevice(internalID: UInt64) throws {
    try store.removeInputDevice(internalID: internalID)
  }

  public func removeVideoComponent(internalID: UInt64) throws {
    try store.removeVideoComponent(internalID: internalID)
  }

  public func removeVision(internalID: UInt64) throws {
    try store.removeVision(internalID: internalID)
  }

  public func setVideoLayerOrder(
    _ layerInternalIDs: [UInt64],
    forProgramInternalID programInternalID: UInt64,
    role: ProgramCanvasRole
  ) throws {
    try store.setVideoLayerOrder(
      layerInternalIDs, forProgramInternalID: programInternalID, role: role)
  }

  public func setBasicTransform(
    _ transform: Ldtx_Workspace_V4_BasicTransform,
    forVideoLayerInternalID layerInternalID: UInt64,
    programInternalID: UInt64,
    role: ProgramCanvasRole
  ) throws {
    try store.setBasicTransform(
      transform,
      forVideoLayerInternalID: layerInternalID,
      programInternalID: programInternalID,
      role: role)
  }

  public func setAudioChannelGain(
    _ gain: Double,
    forAudioInputDeviceInternalID inputDeviceInternalID: UInt64,
    programInternalID: UInt64,
    role: ProgramCanvasRole
  ) throws {
    try store.setAudioChannelGain(
      gain,
      forAudioInputDeviceInternalID: inputDeviceInternalID,
      programInternalID: programInternalID,
      role: role)
  }

  public func setAudioChannelMuted(
    _ muted: Bool,
    forAudioInputDeviceInternalID inputDeviceInternalID: UInt64,
    programInternalID: UInt64,
    role: ProgramCanvasRole
  ) throws {
    try store.setAudioChannelMuted(
      muted,
      forAudioInputDeviceInternalID: inputDeviceInternalID,
      programInternalID: programInternalID,
      role: role)
  }

  public func setVideoLayerMuted(
    _ muted: Bool,
    forVideoLayerInternalID layerInternalID: UInt64,
    programInternalID: UInt64,
    role: ProgramCanvasRole
  ) throws {
    try store.setVideoLayerMuted(
      muted,
      forVideoLayerInternalID: layerInternalID,
      programInternalID: programInternalID,
      role: role)
  }

  public func setMasterVolume(
    _ volume: Double,
    programInternalID: UInt64,
    role: ProgramCanvasRole
  ) throws {
    try store.setMasterVolume(volume, programInternalID: programInternalID, role: role)
  }

  public func setMonitorVolume(_ volume: Double) throws {
    try store.setMonitorVolume(volume)
  }

  public func runtimeProjection(
    programInternalID: UInt64,
    role: ProgramCanvasRole
  ) throws -> WorkspaceV4RuntimeProjection {
    try persistence.runtimeProjection(programInternalID: programInternalID, role: role)
  }

  public func loadYouTubeStreamKeyConfigurations() throws
    -> [YouTubeRTMPSStreamKeyConfiguration]
  {
    try YouTubeStreamKeyConfigurationStore().load()
  }

  public func saveYouTubeStreamKeyConfigurations(
    _ configurations: [YouTubeRTMPSStreamKeyConfiguration]
  ) throws {
    try YouTubeStreamKeyConfigurationStore().save(configurations)
  }
}
