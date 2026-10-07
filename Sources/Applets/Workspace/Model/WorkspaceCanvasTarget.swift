// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
// SPDX-License-Identifier: Apache-2.0

import LDTXProgram
import LDTXProtos

/// Identifies the fields to read and update for one Program canvas.
public struct WorkspaceCanvasTarget {
  public let layerIDs: WritableKeyPath<Ldtx_Workspace_V4_ProgramDefinition, [UInt64]>
  public let preferences:
    WritableKeyPath<
      Ldtx_Workspace_V4_WorkspacePreferencesV4, [UInt64: Ldtx_Workspace_V4_ProgramPreferences]
    >
  public let profileID: KeyPath<Ldtx_Workspace_V4_CanvasConfiguration, String>
  public let videoBitRate: KeyPath<Ldtx_Workspace_V4_CanvasConfiguration, UInt32>
  public let defaultProfile: ProgramOutputProfile
  public let expectedProfileID: String

  public static var landscape: Self {
    Self(
      layerIDs: \.landscapeVideoLayerInternalIds, preferences: \.landscapeProgramPreferences,
      profileID: \.landscapeProfileID, videoBitRate: \.landscapeVideoBitRate,
      defaultProfile: .sdr1080p60, expectedProfileID: "sdr-landscape-1080p60")
  }

  public static var portrait: Self {
    Self(
      layerIDs: \.portraitVideoLayerInternalIds, preferences: \.portraitProgramPreferences,
      profileID: \.portraitProfileID, videoBitRate: \.portraitVideoBitRate,
      defaultProfile: .sdrPortrait1080p60, expectedProfileID: "sdr-portrait-1080p60")
  }
}

/// A read-only projection of the current persisted values for one canvas.
public struct WorkspaceProgramCanvasSnapshot: Sendable {
  public let audioChannelGainsDecibels: [UInt64: Ldtx_Workspace_V4_Rational32]
  public let programInternalID: UInt64
  public let layerIDs: [UInt64]
  public let preferences: Ldtx_Workspace_V4_ProgramPreferences
  public let outputProfile: ProgramOutputProfile
  public let frameRate: Int

  public init(
    definition: Ldtx_Workspace_V4_WorkspaceDefinitionV4,
    preferences: Ldtx_Workspace_V4_WorkspacePreferencesV4,
    programInternalID: UInt64, target: WorkspaceCanvasTarget
  ) throws {
    guard let program = definition.programs.first(where: { $0.internalID == programInternalID })
    else {
      throw WorkspaceCanvasSnapshotError.missingProgram(programInternalID)
    }
    let config = definition.canvasConfiguration
    let profileID = config[keyPath: target.profileID]
    guard profileID.isEmpty || profileID == target.expectedProfileID else {
      throw WorkspaceCanvasSnapshotError.unsupportedOutputProfile(profileID)
    }
    audioChannelGainsDecibels = preferences.audioChannelGainsDecibels
    self.programInternalID = programInternalID
    layerIDs = program[keyPath: target.layerIDs]
    self.preferences = preferences[keyPath: target.preferences][programInternalID] ?? .init()
    let bitRate = config[keyPath: target.videoBitRate]
    outputProfile =
      bitRate == 0 ? target.defaultProfile : target.defaultProfile.withVideoBitRate(Int(bitRate))
    frameRate = config.frameRate == 0 ? outputProfile.frameRate : Int(config.frameRate)
  }
}

public enum WorkspaceCanvasSnapshotError: Error, Equatable {
  case missingProgram(UInt64)
  case unsupportedOutputProfile(String)
}
