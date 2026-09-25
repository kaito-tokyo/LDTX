// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
//
// SPDX-License-Identifier: Apache-2.0

#if DEBUG
  import Foundation
  import Observation
  import LDTXWorkspaceAppletInterface

  @MainActor
  @Observable
  final class PreviewWorkspaceBundleStore {
    private(set) var workspace: WorkspaceV4Package
    var selectedProgramInternalID: UInt64?
    private var monitorAudioIDs: Set<UInt64> = []
    private var mixSyncIDs: Set<UInt64> = []
    var isDirty: Bool { false }
    var definition: Ldtx_Workspace_V4_WorkspaceDefinitionV4 { workspace.definition.definition }
    var preferences: Ldtx_Workspace_V4_WorkspacePreferencesV4 { workspace.preferences.preferences }

    init() {
      var definition = Ldtx_Workspace_V4_WorkspaceDefinitionV4()
      definition.displayName = "Workspace Sidebar Preview"
      workspace = WorkspaceV4Package(
        definition: WorkspaceV4DefinitionDocument(
          externalID: UUID(), definition: definition),
        preferences: WorkspaceV4PreferencesDocument(
          externalID: UUID(), preferences: Ldtx_Workspace_V4_WorkspacePreferencesV4())
      )
    }

    func editDefinition(
      _ mutation: (inout Ldtx_Workspace_V4_WorkspaceDefinitionV4) -> Void
    ) {
      mutation(&workspace.definition.definition)
    }

    func editPreferences(
      _ mutation: (inout Ldtx_Workspace_V4_WorkspacePreferencesV4) -> Void
    ) {
      mutation(&workspace.preferences.preferences)
    }

    func synchronizesLandscapeMixToPortrait(for programInternalID: UInt64) -> Bool {
      mixSyncIDs.contains(programInternalID)
    }
    func setSynchronizesLandscapeMixToPortrait(_ enabled: Bool, for programInternalID: UInt64) {
      if enabled {
        mixSyncIDs.insert(programInternalID)
      } else {
        mixSyncIDs.remove(programInternalID)
      }
    }
    func monitorsAudioInputDevice(_ inputDeviceInternalID: UInt64) -> Bool {
      monitorAudioIDs.contains(inputDeviceInternalID)
    }
    func setMonitorsAudioInputDevice(_ enabled: Bool, for inputDeviceInternalID: UInt64) {
      if enabled {
        monitorAudioIDs.insert(inputDeviceInternalID)
      } else {
        monitorAudioIDs.remove(inputDeviceInternalID)
      }
    }
  }

  extension PreviewWorkspaceBundleStore: @MainActor WorkspaceBundleStoreProtocol {}
#endif
