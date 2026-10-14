// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
//
// SPDX-License-Identifier: Apache-2.0

import Foundation
import LDTXProtos
import LDTXWorkspaceAppletModel

public protocol WorkspaceRuntimeActions: AnyObject {
  @MainActor func classify(
    vision: Ldtx_Workspace_V4_LdtxSceneDetectorVision, modelURL: URL
  ) async throws -> String
  @MainActor func synchronizeAudioMonitor()
  @MainActor func synchronizeCaptureInputs(
    availableCameraIDs: Set<String>,
    completionHandler: @escaping @Sendable (Set<String>) -> Void)
  @MainActor func removeProgram(internalID: Int64) throws
  @MainActor func selectProgram(internalID: Int64) throws
  @MainActor func updateProgramRuntimes()
  @MainActor func startOutput() async throws
  @MainActor func pauseOutput() async
  @MainActor func stopOutput() async
  @MainActor func updateMixPreferences()
  @MainActor func captureScreenshots() throws -> [WorkspaceScreenshot]
  @MainActor func openScreenshotsDirectory()
}
