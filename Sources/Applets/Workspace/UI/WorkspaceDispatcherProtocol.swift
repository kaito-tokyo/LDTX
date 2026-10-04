// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
//
// SPDX-License-Identifier: Apache-2.0

import Foundation
import LDTXWorkspaceAppletInterface
import Observation

public protocol WorkspaceDispatcherProtocol: AnyObject, Observable {
  @MainActor func synchronizeVision()
  @MainActor func synchronizeAudioMonitor()
  @MainActor func synchronizeCaptureInputs(
    availableCameraIDs: Set<String>,
    completionHandler: @escaping @Sendable (Set<String>) -> Void)
  @MainActor func selectProgram(internalID: UInt64) throws
  @MainActor func setBasicTransform(
    _ transform: Ldtx_Workspace_V4_BasicTransform, programInternalID: UInt64,
    videoLayerInternalID: UInt64, target: WorkspaceCanvasTarget
  ) throws
  @MainActor func updateProgramRuntimes()
  @MainActor func startOutput() async throws
  @MainActor func pauseOutput() async
  @MainActor func stopOutput() async
  @MainActor func updateMixPreferences()
  @MainActor func captureScreenshots() throws -> [URL]
  @MainActor func openScreenshotsDirectory()
}
