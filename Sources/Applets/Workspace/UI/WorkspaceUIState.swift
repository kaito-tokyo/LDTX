// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
//
// SPDX-License-Identifier: Apache-2.0

import Foundation
import LDTXProtos
import LDTXWorkspaceAppletInterface
import Observation

@MainActor
@Observable
public final class WorkspaceUIState {
  public typealias WorkspaceDefinition = Ldtx_Workspace_V4_WorkspaceDefinitionV4
  public typealias VideoComponentWrapper = Ldtx_Workspace_V4_VideoComponentWrapper
  public typealias WorkspacePreferences = Ldtx_Workspace_V4_WorkspacePreferencesV4

  public var definition: WorkspaceDefinition {
    didSet {
      if definition != oldValue { documentContentsDidChange?() }
    }
  }
  public var preferences: WorkspacePreferences {
    didSet { if preferences != oldValue { documentContentsDidChange?() } }
  }

  @ObservationIgnored public var documentContentsDidChange: (() -> Void)?
  public var localStateURL: URL?

  public var inspectorSelector: WorkspaceInspectorSelector?

  @ObservationIgnored public var documentOutputStateDidChange: (() -> Void)?
  public var isOutputActive = false {
    didSet { if isOutputActive != oldValue { documentOutputStateDidChange?() } }
  }
  public var recordingState: WorkspaceRecordingState = .idle
  public var isLocalRecording = false
  public var outputFailureMessage: String?

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

}
