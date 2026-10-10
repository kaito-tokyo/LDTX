// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
//
// SPDX-License-Identifier: Apache-2.0

import Foundation
import LDTXProgramRuntime
import LDTXProtos
import LDTXWorkspaceAppletModel
import Observation

@MainActor
@Observable
public final class WorkspaceStoreService {
  public var workspaceDefinition: Ldtx_Workspace_V4_WorkspaceDefinitionV4
  public var workspaceOutputSettings: Ldtx_Workspace_V4_WorkspaceOutputSettingsV4
  public var workspacePreferences: Ldtx_Workspace_V4_WorkspacePreferencesV4
  public var externalID: String?
  public var localStateURL: URL?

  public var selectedAudioMix: ProgramAudioPeakMeter.Master = .landscape

  public var inspectorSelector: WorkspaceInspectorSelector?
  public var isInspectorVisible = true

  public var isOutputActive = false
  public var recordingState: WorkspaceRecordingState = .idle
  public var isLocalRecording = false
  public var outputFailureMessage: String?
  public var visionResults: [Int64: String] = [:]
  public var visionFailureMessages: [Int64: String] = [:]

  public init(
    definition: Ldtx_Workspace_V4_WorkspaceDefinitionV4 = .init(),
    preferences: Ldtx_Workspace_V4_WorkspacePreferencesV4 = .init(),
    inspectorSelector: WorkspaceInspectorSelector? = nil,
    isOutputActive: Bool = false,
    isLocalRecording: Bool = false,
    outputFailureMessage: String? = nil,
    outputSettings: Ldtx_Workspace_V4_WorkspaceOutputSettingsV4 = .init()
  ) {
    self.workspaceDefinition = definition
    self.workspaceOutputSettings = outputSettings
    self.workspacePreferences = preferences
    self.inspectorSelector = inspectorSelector
    self.isOutputActive = isOutputActive
    self.isLocalRecording = isLocalRecording
    self.outputFailureMessage = outputFailureMessage
  }

}

public struct WorkspaceSaveValidationError: LocalizedError, Sendable {
  public let messages: [String]

  public init(messages: [String]) { self.messages = messages }

  public var errorDescription: String? { "The Workspace could not be saved." }
  public var failureReason: String? { messages.joined(separator: "\n\n") }
  public var recoverySuggestion: String? {
    messages.joined(separator: "\n\n") + "\n\nCorrect these settings and save again."
  }
}
