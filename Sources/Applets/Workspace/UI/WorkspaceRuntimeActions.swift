// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
//
// SPDX-License-Identifier: Apache-2.0

import Foundation
import LDTXProtos
import LDTXWorkspaceAppletModel

public protocol WorkspaceRuntimeActions: AnyObject {
  @MainActor func actionState(_ action: WorkspaceAction) -> WorkspaceActionState
  /// Revalidates admission and handles errors. Returns files only for a successful capture.
  @discardableResult @MainActor func perform(_ action: WorkspaceAction) async
    -> [WorkspaceScreenshot]?
  @MainActor var latestRecordingBundleURL: URL? { get }
  @MainActor func classify(
    vision: Ldtx_Workspace_V4_LdtxSceneDetectorVision, modelURL: URL
  ) async throws -> String
  @discardableResult @MainActor func updateDeviceAssignments(availableCameraIDs: Set<String>) throws
    -> Task<WorkspaceCommandOutcome, Never>
  @MainActor func synchronizeAudioMonitor()
  @MainActor func updateAudioMonitorValues()
  @MainActor func synchronizeCaptureInputs(
    availableCameraIDs: Set<String>,
    completionHandler: @escaping @Sendable (Set<String>) -> Void)
  @MainActor func removeProgram(internalID: Int64, undoManager: UndoManager?) throws
  @discardableResult @MainActor func selectProgram(internalID: Int64) throws -> Task<
    WorkspaceCommandOutcome, Never
  >
  @MainActor func updateProgramRuntimes()
  @MainActor func startOutput() async throws
  @MainActor func pauseOutput() async
  @MainActor func stopOutput() async
  @MainActor func updateMixPreferences()
  @MainActor func captureScreenshots() throws -> [WorkspaceScreenshot]
  @MainActor func openScreenshotsDirectory()
}
