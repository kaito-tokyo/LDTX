// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
//
// SPDX-License-Identifier: Apache-2.0

import Foundation
import Observation

public protocol WorkspaceDispatcherProtocol: AnyObject, Observable {
  @MainActor func saveWorkspaceDefinition() async throws
  @MainActor func saveWorkspacePreferences() async throws
  @MainActor func synchronizeVision()
  @MainActor func synchronizeAudioMonitor()
  @MainActor func startOutput() async throws
  @MainActor func stopOutput() async
  @MainActor func updateMixPreferences()
  @MainActor func captureScreenshots() throws -> [URL]
  @MainActor func openScreenshotsDirectory()
}
