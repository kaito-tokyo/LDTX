// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
//
// SPDX-License-Identifier: Apache-2.0

import LDTXWorkspaceAppletUI
import Observation

private enum WorkspaceDispatcherError: Error {
  case workspaceClosed
}

@MainActor
@Observable
final class WorkspaceDispatcher: WorkspaceDispatcherProtocol {
  @ObservationIgnored
  public weak var workspaceAppletController: WorkspaceAppletController?

  init() {}

  func saveWorkspaceDefinition() async throws {
    guard let workspaceAppletController else {
      throw WorkspaceDispatcherError.workspaceClosed
    }
    try workspaceAppletController.saveWorkspaceDefinition()
  }

  func saveWorkspacePreferences() async throws {
    guard let workspaceAppletController else {
      throw WorkspaceDispatcherError.workspaceClosed
    }
    try workspaceAppletController.saveWorkspacePreferences()
  }
}
