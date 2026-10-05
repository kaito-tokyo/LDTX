// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
//
// SPDX-License-Identifier: Apache-2.0

import Foundation
import LDTXWorkspaceAppletInterface
import LDTXWorkspaceAppletUI
import Observation

private enum WorkspaceDispatcherError: Error {
  case workspaceClosed
}

@MainActor
@Observable
final class WorkspaceDispatcher: WorkspaceDispatcherProtocol {
  @ObservationIgnored
  public weak var workspaceWindowController: WorkspaceWindowController?

  init() {}

  func synchronizeVision() {
    workspaceWindowController?.synchronizeVision()
  }

  func synchronizeAudioMonitor() {
    workspaceWindowController?.synchronizeAudioMonitor()
  }

  func synchronizeCaptureInputs(
    availableCameraIDs: Set<String>,
    completionHandler: @escaping @Sendable (Set<String>) -> Void
  ) {
    workspaceWindowController?.synchronizeCaptureInputs(
      availableCameraIDs: availableCameraIDs, completionHandler: completionHandler)
  }

  func selectProgram(internalID: UInt64) throws {
    guard let workspaceWindowController else { throw WorkspaceDispatcherError.workspaceClosed }
    try workspaceWindowController.selectProgram(internalID: internalID)
  }

  func updateProgramRuntimes() {
    workspaceWindowController?.updateProgramRuntimes()
  }

  func startOutput() async throws {
    guard let workspaceWindowController else {
      throw WorkspaceDispatcherError.workspaceClosed
    }
    try await workspaceWindowController.startOutput()
  }

  func pauseOutput() async {
    await workspaceWindowController?.pauseOutput()
  }

  func stopOutput() async {
    await workspaceWindowController?.stopOutput()
  }

  func updateMixPreferences() {
    workspaceWindowController?.updateMixPreferences()
  }

  func captureScreenshots() throws -> [URL] {
    guard let workspaceWindowController else {
      throw WorkspaceDispatcherError.workspaceClosed
    }
    return try workspaceWindowController.captureScreenshots()
  }

  func openScreenshotsDirectory() {
    workspaceWindowController?.openScreenshotsDirectory()
  }
}
