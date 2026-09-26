// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
//
// SPDX-License-Identifier: Apache-2.0

import Foundation
import LDTXCapture
import LDTXProgram
import LDTXProgramRuntime
import LDTXWorkspaceAppletModel
import LDTXYouTubeRTMPS
import Observation

@MainActor
public protocol WorkspaceSessionProtocol: AnyObject, Observable {
  var url: URL? { get }
  var selectedProgramInternalID: UInt64? { get set }
  var definition: Ldtx_Workspace_V4_WorkspaceDefinitionV4 { get }
  var preferences: Ldtx_Workspace_V4_WorkspacePreferencesV4 { get }
  var landscapeYouTubeLiveStreamID: String? { get }
  var portraitYouTubeLiveStreamID: String? { get }

  func editDefinition(_ mutation: (inout Ldtx_Workspace_V4_WorkspaceDefinitionV4) -> Void) throws
  func availableCaptureDevices() -> (
    cameras: [CameraCaptureSource], audioDevices: [AudioCaptureSource]
  )
  func setLandscapeYouTubeLiveStreamID(_ streamID: String?)
  func setPortraitYouTubeLiveStreamID(_ streamID: String?)
  func setVideoLayerOrder(
    _ layerInternalIDs: [UInt64], forProgramInternalID: UInt64, role: ProgramCanvasRole) throws
  func setBasicTransform(
    _ transform: Ldtx_Workspace_V4_BasicTransform, forVideoLayerInternalID: UInt64,
    programInternalID: UInt64, role: ProgramCanvasRole) throws
  func setAudioChannelGain(
    _ gain: Double, forAudioInputDeviceInternalID: UInt64, programInternalID: UInt64,
    role: ProgramCanvasRole) throws
  func setAudioChannelMuted(
    _ muted: Bool, forAudioInputDeviceInternalID: UInt64, programInternalID: UInt64,
    role: ProgramCanvasRole) throws
  func setVideoLayerMuted(
    _ muted: Bool, forVideoLayerInternalID: UInt64, programInternalID: UInt64,
    role: ProgramCanvasRole) throws
  func setMasterVolume(_ volume: Double, programInternalID: UInt64, role: ProgramCanvasRole) throws
  func setMonitorVolume(_ volume: Double) throws
  func addVideoInputDevice(displayName: String) throws -> UInt64
  func addAudioInputDevice(displayName: String) throws -> UInt64
  func addProgram(displayName: String) throws -> UInt64
  func addVFXSource(displayName: String, inputDeviceInternalID: UInt64) throws -> UInt64
  func addSolidColorFill(displayName: String, color: Ldtx_Workspace_V4_ExtendedSrgbColor) throws
    -> UInt64
  func addLinearGradientFill(
    displayName: String, startColor: Ldtx_Workspace_V4_ExtendedSrgbColor,
    endColor: Ldtx_Workspace_V4_ExtendedSrgbColor
  ) throws -> UInt64
  func addRadialGradientFill(
    displayName: String, innerColor: Ldtx_Workspace_V4_ExtendedSrgbColor,
    outerColor: Ldtx_Workspace_V4_ExtendedSrgbColor
  ) throws -> UInt64
  func addConicGradientFill(
    displayName: String, startColor: Ldtx_Workspace_V4_ExtendedSrgbColor,
    endColor: Ldtx_Workspace_V4_ExtendedSrgbColor
  ) throws -> UInt64
  func addClock(displayName: String) throws -> UInt64
  func addTestPattern(displayName: String) throws -> UInt64
  func addOcrVision(displayName: String, inputDeviceInternalID: UInt64, intervalSeconds: Double)
    throws -> UInt64
  func updateRuntimes()
  func synchronizeCaptureInputs(
    availableCameraIDs: Set<String>, completionHandler: @escaping @Sendable (Set<String>) -> Void)
  func runtime(for role: ProgramCanvasRole) -> ProgramRuntime?
  func save(to packageURL: URL) throws
  func loadYouTubeStreamKeyConfigurations() throws -> [YouTubeRTMPSStreamKeyConfiguration]
  func saveYouTubeStreamKeyConfigurations(_ configurations: [YouTubeRTMPSStreamKeyConfiguration])
    throws
}

extension WorkspaceSessionProtocol {
  public func addSolidColorFill(displayName: String) throws -> UInt64 {
    try addSolidColorFill(displayName: displayName, color: .init())
  }

  public func addLinearGradientFill(displayName: String) throws -> UInt64 {
    var start = Ldtx_Workspace_V4_ExtendedSrgbColor()
    start.red = 1
    start.green = 1
    start.blue = 1
    start.alpha = 1
    var end = Ldtx_Workspace_V4_ExtendedSrgbColor()
    end.red = 0.15
    end.green = 0.35
    end.blue = 0.85
    end.alpha = 1
    return try addLinearGradientFill(displayName: displayName, startColor: start, endColor: end)
  }

  public func addRadialGradientFill(displayName: String) throws -> UInt64 {
    try addRadialGradientFill(
      displayName: displayName, innerColor: defaultGradientStart, outerColor: defaultGradientEnd)
  }

  public func addConicGradientFill(displayName: String) throws -> UInt64 {
    try addConicGradientFill(
      displayName: displayName, startColor: defaultGradientStart, endColor: defaultGradientEnd)
  }

  public func addOcrVision(displayName: String, inputDeviceInternalID: UInt64) throws -> UInt64 {
    try addOcrVision(
      displayName: displayName, inputDeviceInternalID: inputDeviceInternalID,
      intervalSeconds: 5)
  }

  private var defaultGradientStart: Ldtx_Workspace_V4_ExtendedSrgbColor {
    var color = Ldtx_Workspace_V4_ExtendedSrgbColor()
    color.red = 1
    color.green = 1
    color.blue = 1
    color.alpha = 1
    return color
  }

  private var defaultGradientEnd: Ldtx_Workspace_V4_ExtendedSrgbColor {
    var color = Ldtx_Workspace_V4_ExtendedSrgbColor()
    color.red = 0.15
    color.green = 0.35
    color.blue = 0.85
    color.alpha = 1
    return color
  }
}
