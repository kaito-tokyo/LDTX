// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
//
// SPDX-License-Identifier: Apache-2.0

import Foundation

public struct WorkspaceV4Bundle: Equatable {
  public var definitionExternalID: String?
  public var preferencesExternalID: String?
  public var definition: Ldtx_Workspace_V4_WorkspaceDefinitionV4
  public var preferences: Ldtx_Workspace_V4_WorkspacePreferencesV4

  public init(
    definitionExternalID: String? = nil,
    preferencesExternalID: String? = nil,
    definition: Ldtx_Workspace_V4_WorkspaceDefinitionV4,
    preferences: Ldtx_Workspace_V4_WorkspacePreferencesV4
  ) {
    self.definitionExternalID = definitionExternalID
    self.preferencesExternalID = preferencesExternalID
    self.definition = definition
    self.preferences = preferences
  }
}
