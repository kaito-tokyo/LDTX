// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
//
// SPDX-License-Identifier: Apache-2.0

import Foundation
import LDTXProtos

public struct WorkspaceV4Bundle: Equatable, Sendable {
  public var models: [String: Data]
  public var definitionExternalID: String?
  public var preferencesExternalID: String?
  public var outputSettingsExternalID: String?
  public var definition: Ldtx_Workspace_V4_WorkspaceDefinitionV4
  public var preferences: Ldtx_Workspace_V4_WorkspacePreferencesV4
  public var outputSettings: Ldtx_Workspace_V4_WorkspaceOutputSettingsV4

  public init(
    definitionExternalID: String? = nil,
    preferencesExternalID: String? = nil,
    definition: Ldtx_Workspace_V4_WorkspaceDefinitionV4,
    preferences: Ldtx_Workspace_V4_WorkspacePreferencesV4,
    outputSettingsExternalID: String? = nil,
    outputSettings: Ldtx_Workspace_V4_WorkspaceOutputSettingsV4 = .init(),
    models: [String: Data] = [:]
  ) {
    self.models = models
    self.definitionExternalID = definitionExternalID
    self.preferencesExternalID = preferencesExternalID
    self.definition = definition
    self.preferences = preferences
    self.outputSettingsExternalID = outputSettingsExternalID
    self.outputSettings = outputSettings
  }
}


extension WorkspaceV4IntegrityValidator {
  public static func validate(_ workspace: WorkspaceV4Bundle) throws {
    if let issue = validationIssues(in: workspace).first { throw issue.error }
  }

  public static func validationIssues(in workspace: WorkspaceV4Bundle)
    -> [WorkspaceV4ValidationIssue]
  {
    validationIssues(in: workspace.definition, preferences: workspace.preferences)
  }
}
