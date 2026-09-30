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

  public var inspectorSelector: WorkspaceInspectorSelector?

  public private(set) var isDirty = false
  public var isOutputActive = false
  public var isLocalRecording = false
  public var outputFailureMessage: String?

  @ObservationIgnored private var hasUnsavedDefinitionChanges = false
  @ObservationIgnored private var hasUnsavedPreferencesChanges = false

  public init(
    definition: WorkspaceDefinition,
    preferences: WorkspacePreferences,
    inspectorSelector: WorkspaceInspectorSelector? = .init(kind: .programVideoLayers),
    isOutputActive: Bool = false,
    isLocalRecording: Bool = false,
    outputFailureMessage: String? = nil
  ) {
    self.definition = definition
    self.preferences = preferences
    self.inspectorSelector = inspectorSelector
    self.isOutputActive = isOutputActive
    self.isLocalRecording = isLocalRecording
    self.outputFailureMessage = outputFailureMessage
  }

  public func recordDefinitionChange() {
    hasUnsavedDefinitionChanges = true
    updateDirtyState()
  }

  public func recordPreferencesChange() {
    hasUnsavedPreferencesChanges = true
    updateDirtyState()
  }

  public func markDefinitionSaved() {
    hasUnsavedDefinitionChanges = false
    updateDirtyState()
  }

  public func markPreferencesSaved() {
    hasUnsavedPreferencesChanges = false
    updateDirtyState()
  }

  public func markAllSaved() {
    hasUnsavedDefinitionChanges = false
    hasUnsavedPreferencesChanges = false
    updateDirtyState()
  }

  private func updateDirtyState() {
    isDirty = hasUnsavedDefinitionChanges || hasUnsavedPreferencesChanges
  }
}
