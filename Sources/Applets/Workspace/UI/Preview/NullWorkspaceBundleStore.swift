// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
//
// SPDX-License-Identifier: Apache-2.0

#if DEBUG
  import Foundation
  import LDTXWorkspaceAppletInterface
  import Observation

  @MainActor
  @Observable
  final class NullWorkspaceBundleStore {
    private(set) var workspace = WorkspaceV4Package(
      definition: WorkspaceV4DefinitionDocument(
        externalID: UUID(), definition: .init()),
      preferences: WorkspaceV4PreferencesDocument(
        externalID: UUID(), preferences: .init()))
    var definition: Ldtx_Workspace_V4_WorkspaceDefinitionV4 { workspace.definition.definition }
    var preferences: Ldtx_Workspace_V4_WorkspacePreferencesV4 {
      workspace.preferences.preferences
    }
    var isDirty: Bool { false }
    var selectedProgramInternalID: UInt64? {
      get { nil }
      set {}
    }

    func editDefinition(
      _ mutation: (inout Ldtx_Workspace_V4_WorkspaceDefinitionV4) -> Void
    ) {}

    func editPreferences(
      _ mutation: (inout Ldtx_Workspace_V4_WorkspacePreferencesV4) -> Void
    ) {}

    func synchronizesLandscapeMixToPortrait(for programInternalID: UInt64) -> Bool { false }

    func setSynchronizesLandscapeMixToPortrait(
      _ enabled: Bool, for programInternalID: UInt64
    ) {}

    func monitorsAudioInputDevice(_ inputDeviceInternalID: UInt64) -> Bool { false }

    func setMonitorsAudioInputDevice(
      _ enabled: Bool, for inputDeviceInternalID: UInt64
    ) {}
  }

  extension NullWorkspaceBundleStore: @MainActor WorkspaceBundleStoreProtocol {}
#endif
