// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
//
// SPDX-License-Identifier: Apache-2.0

import LDTXWorkspaceAppletModel
import Observation

public enum WorkspaceRecordingState: Equatable {
  case idle
  case starting
  case recording
  case stopping
  case failed(String)
}

public protocol WorkspaceBundleStoreProtocol: AnyObject, Observable {
  var workspace: WorkspaceV4Package { get }
  var definition: Ldtx_Workspace_V4_WorkspaceDefinitionV4 { get }
  var preferences: Ldtx_Workspace_V4_WorkspacePreferencesV4 { get }
  var isDirty: Bool { get }
  var selectedProgramInternalID: UInt64? { get set }

  func editDefinition(
    _ mutation: (inout Ldtx_Workspace_V4_WorkspaceDefinitionV4) -> Void
  )
  func editPreferences(
    _ mutation: (inout Ldtx_Workspace_V4_WorkspacePreferencesV4) -> Void
  )
  func synchronizesLandscapeMixToPortrait(for programInternalID: UInt64) -> Bool
  func setSynchronizesLandscapeMixToPortrait(_ enabled: Bool, for programInternalID: UInt64)
  func monitorsAudioInputDevice(_ inputDeviceInternalID: UInt64) -> Bool
  func setMonitorsAudioInputDevice(_ enabled: Bool, for inputDeviceInternalID: UInt64)
}
