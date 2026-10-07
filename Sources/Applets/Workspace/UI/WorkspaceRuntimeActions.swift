// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
//
// SPDX-License-Identifier: Apache-2.0

import Foundation
import LDTXWorkspaceAppletInterface

public protocol WorkspaceRuntimeActions: AnyObject {
  @MainActor func synchronizeVision()
  @MainActor func synchronizeAudioMonitor()
  @MainActor func synchronizeCaptureInputs(
    availableCameraIDs: Set<String>,
    completionHandler: @escaping @Sendable (Set<String>) -> Void)
  @MainActor func removeProgram(internalID: UInt64) throws
  @MainActor func selectProgram(internalID: UInt64) throws
  @MainActor func updateProgramRuntimes()
  @MainActor func startOutput() async throws
  @MainActor func pauseOutput() async
  @MainActor func stopOutput() async
  @MainActor func updateMixPreferences()
  @MainActor func captureScreenshots() throws -> [URL]
  @MainActor func openScreenshotsDirectory()
}
