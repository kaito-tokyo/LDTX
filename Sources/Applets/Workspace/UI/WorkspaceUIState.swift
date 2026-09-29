// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
//
// SPDX-License-Identifier: Apache-2.0

import LDTXProtos
import Observation

@MainActor
@Observable
public final class WorkspaceUIState {
  public typealias WorkspaceDefinition = Ldtx_Workspace_V4_WorkspaceDefinitionV4
  public typealias VideoComponentWrapper = Ldtx_Workspace_V4_VideoComponentWrapper
  public typealias WorkspacePreferences = Ldtx_Workspace_V4_WorkspacePreferencesV4

  public var definition: WorkspaceDefinition
  public var preferences: WorkspacePreferences

  public var inspectorKind: WorkspaceInspectorKind? = .programVideoLayers
  public var isDirty = false
  public var isOutputActive = false

  public init(
    definition: WorkspaceDefinition,
    preferences: WorkspacePreferences,
    inspectorKind: WorkspaceInspectorKind? = .programVideoLayers,
    isOutputActive: Bool = false
  ) {
    self.definition = definition
    self.preferences = preferences
    self.inspectorKind = inspectorKind
    self.isOutputActive = isOutputActive
  }
}
