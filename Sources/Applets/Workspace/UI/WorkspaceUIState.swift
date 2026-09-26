// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
//
// SPDX-License-Identifier: Apache-2.0

import LDTXProtos
import Observation

@MainActor
@Observable
public final class WorkspaceUIState {
  public var definition: Ldtx_Workspace_V4_WorkspaceDefinitionV4
  public var preferences: Ldtx_Workspace_V4_WorkspacePreferencesV4
  public var inspectorKind: WorkspaceInspectorKind?

  public init(
    definition: Ldtx_Workspace_V4_WorkspaceDefinitionV4,
    preferences: Ldtx_Workspace_V4_WorkspacePreferencesV4,
    inspectorKind: WorkspaceInspectorKind?
  ) {
    self.definition = definition
    self.preferences = preferences
    self.inspectorKind = inspectorKind
  }
}
